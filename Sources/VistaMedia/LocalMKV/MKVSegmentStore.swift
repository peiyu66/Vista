#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation
import CryptoKit
import Darwin

struct MKVStoreReply: Sendable { let id: UUID; let data: Data }
struct MKVStoreSnapshot: Codable, Sendable {
    let retiring: Bool; let cleaned: Bool; let published: [String]; let playlist: [String]
    let liveLeases: Int; let responseBytes: Int; let drainAcknowledged: Bool
    let pendingHighWater: Int; let publishedHighWater: Int; let responseHighWater: Int; let leaseHighWater: Int
}
enum MKVStoreError: Error { case rejected(String); case system(String, Int32) }

// Fixed disk/window policy. This is not a process RSS or decoder memory bound.
enum MKVWindowBudget {
    static let segmentCountCap=Int(SAP_STARTUP_SEGMENT_MAX)
    static let payloadCap=33_554_432, initCap=1_048_576, activeCap=134_217_728, storeCap=402_653_184
    struct Entry: Sendable {let index:Int;let duration:Double;let globalEnd:Double;let bytes:Int}
    static func retained(_ values:[Entry],now:Double,targetDuration:Int,startup:Bool)->[Entry] {
        var kept=values
        if !startup {
            while kept.count>1 && kept[0].globalEnd<now && kept.dropFirst().reduce(0,{$0+$1.duration})>=Double(targetDuration*3) {kept.removeFirst()}
        }
        return kept
    }
    static func byteCount(_ values:[Entry])->Int {values.reduce(0,{$0+$1.bytes})}
    static func admits(_ values:[Entry],startup:Bool)->Bool {
        !values.isEmpty && values.count <= segmentCountCap &&
        values.allSatisfy{$0.bytes>0 && $0.bytes<=payloadCap} && byteCount(values)<=activeCap
    }
}

// State and all file IO belong exclusively to queue. No blocking waits on MainActor.
final class MKVSegmentStore: @unchecked Sendable {
    static let payloadCap = MKVWindowBudget.payloadCap, aggregateCap = MKVWindowBudget.storeCap, responseCap = 16_384, leaseCap = 4
    private let queue = DispatchQueue(label: "research.coupled.store")
    private let stamp: BridgeStamp
    private var parentFD: Int32 = -1, directoryFD: Int32 = -1
    private let name: String
    private var retiring = false, cleaned = false, drained = false
    private struct File { let inode: ino_t; let device: dev_t; let size: Int }
    private struct Pending { let name: String; let file: File; let hash: String }
    private struct Lease { let fd: Int32; let size: Int; let name: String }
    private var files: [String: File] = [:], leases: [UUID: Lease] = [:], replies: [UUID: (UUID, Int)] = [:]
    private var pending: Pending?, playlist: [String] = []
    private var currentManifest: String?
    private var manifestNumber = 0
    private var removedAt: [String: UInt64] = [:]
    private var retentionNS: [String: UInt64] = [:]
    private var history: [[String: String]] = []
    static func validName(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.utf8.count <= 40 else { return false }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber } && Int(digits).map { $0 > 0 && $0 < Int.max } == true
    }
    private func addHistory(_ value: [String:String]) { if history.count == 128 { history.removeFirst() }; history.append(value) }
    private func monotonicNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private var total = 0, responseBytes = 0, pendingHigh = 0, publishedHigh = 0, responseHigh = 0, leaseHigh = 0
    private init(name: String, stamp: BridgeStamp) { self.name = name; self.stamp = stamp }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { do { c.resume(returning: try body()) } catch { c.resume(throwing: error) } } }
    }
    private func require(_ yes: Bool, _ why: String) throws { if !yes { throw MKVStoreError.rejected(why) } }
    private func syscall(_ result: Int32, _ why: String) throws { if result < 0 { throw MKVStoreError.system(why, errno) } }
    private func validate(_ s: BridgeStamp, active: Bool = true) throws {
        try require(s == stamp && !cleaned, "stamp/cleaned")
        if active { try require(!retiring, "retiring") }
    }
    static func create(parent: URL, name: String, stamp: BridgeStamp) async throws -> MKVSegmentStore {
        let store = MKVSegmentStore(name: name, stamp: stamp)
        return try await store.perform {
            try store.require(!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0), "directory name")
            store.parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            try store.syscall(store.parentFD, "parent open")
            do {
                try store.syscall(mkdirat(store.parentFD, name, 0o700), "mkdir owned")
                store.directoryFD = openat(store.parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                try store.syscall(store.directoryFD, "owned open")
            } catch { close(store.parentFD); store.parentFD = -1; throw error }
            return store
        }
    }
    func stage(stamp s: BridgeStamp, name: String, data: Data) async throws -> String {
        try await perform {
            try self.validate(s)
            let allowed = name == "init.mp4" || Self.validName(name, prefix: "segment-", suffix: ".m4s") || Self.validName(name, prefix: "manifest-", suffix: ".m3u8")
            try self.require(allowed && self.files[name] == nil && self.pending == nil && self.files.count < 64, "name/overwrite/pending/file cap")
            try self.require(!data.isEmpty && data.count <= Self.payloadCap && self.total + data.count <= Self.aggregateCap, "size cap")
            let fd = openat(self.directoryFD, ".pending", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            try self.syscall(fd, "pending open")
            var opened = true
            do {
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < data.count {
                        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                        if n <= 0 { throw MKVStoreError.system("write", errno) }; offset += n
                    }
                }
                try self.syscall(fsync(fd), "fsync")
                var st = stat(); try self.syscall(fstat(fd, &st), "fstat")
                try self.require(st.st_size == data.count && (st.st_mode & S_IFMT) == S_IFREG, "closed payload size/type")
                try self.syscall(fchmod(fd, 0o400), "immutable mode")
                let result = close(fd); opened = false; try self.syscall(result, "close payload")
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                self.pending = Pending(name: name, file: File(inode: st.st_ino, device: st.st_dev, size: data.count), hash: hash)
                self.pendingHigh = max(self.pendingHigh, data.count)
                return hash
            } catch {
                if opened { close(fd) }; unlinkat(self.directoryFD, ".pending", 0); throw error
            }
        }
    }
    func commit(stamp s: BridgeStamp, expectedSHA256: String) async throws {
        try await perform {
            try self.validate(s) // Recheck after stage; retirement cannot publish staged payload.
            guard let p = self.pending else { throw MKVStoreError.rejected("no stage") }
            try self.require(p.hash == expectedSHA256 && self.files[p.name] == nil, "hash/overwrite")
            var staged = stat(); try self.syscall(fstatat(self.directoryFD, ".pending", &staged, AT_SYMLINK_NOFOLLOW), "stage identity"); try self.check(staged, p.file)
            // Hard-link is atomic and fails EEXIST, unlike overwrite rename.
            try self.syscall(linkat(self.directoryFD, ".pending", self.directoryFD, p.name, 0), "publish no-replace")
            self.files[p.name] = p.file; self.total += p.file.size
            try self.syscall(unlinkat(self.directoryFD, ".pending", 0), "remove stage name")
            self.pending = nil; self.publishedHigh = max(self.publishedHigh, self.total)
        }
    }
    func publishPlaylist(stamp s: BridgeStamp, segments: [String]) async throws {
        try await perform {
            try self.validate(s)
            try self.require(segments.count <= MKVWindowBudget.segmentCountCap && Set(segments).count == segments.count && self.files["init.mp4"] != nil && segments.allSatisfy { $0.hasPrefix("segment-") && self.files[$0] != nil }, "playlist references")
            self.playlist = segments
        }
    }
    func publishedSize(stamp s: BridgeStamp, name: String) async throws -> Int {
        try await perform { try self.validate(s); let resolved = name == "index.m3u8" ? self.currentManifest ?? "unpublished" : name; guard let file = self.files[resolved] else { throw MKVStoreError.rejected("unpublished") }; return file.size }
    }
    func publishManifest(stamp s: BridgeStamp, segments: [String], data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        let referenced = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).split(separator: ",")[0]) }
        try require(referenced == segments && !segments.isEmpty && segments.count <= MKVWindowBudget.segmentCountCap && durations.count == segments.count && durations.allSatisfy { $0 > 0 && $0 <= 10 } && text.contains("URI=\"init.mp4\"") && !text.contains("#EXT-X-PLAYLIST-TYPE") && data.count <= 4096, "rolling manifest contract")
        let prepared: String = try await perform {
            try self.validate(s)
            try self.require(self.files["init.mp4"] != nil && segments.allSatisfy { self.files[$0] != nil }, "unpublished rolling references")
            self.manifestNumber += 1; try self.require(self.manifestNumber < Int.max, "manifest version cap")
            return String(format: "manifest-%03d.m3u8", self.manifestNumber)
        }
        let hash = try await stage(stamp: s, name: prepared, data: data)
        try await commit(stamp: s, expectedSHA256: hash)
        try await perform {
            try self.validate(s)
            let now = self.monotonicNS(), oldManifest = self.currentManifest
            let longest = durations.reduce(0, +)
            for (index, name) in segments.enumerated() {
                let ttl = UInt64(ceil((longest + durations[index]) * 1_000_000_000))
                self.retentionNS[name] = max(self.retentionNS[name] ?? 0, ttl)
            }
            for removed in self.playlist where !segments.contains(removed) { self.removedAt[removed] = now }
            self.currentManifest = prepared; self.playlist = segments
            self.addHistory(["event":"manifestPublished", "name":prepared, "clockNS":String(now), "segments":segments.joined(separator:",")])
            if let oldManifest { self.removedAt[oldManifest] = now; self.retentionNS[oldManifest] = 0 }
            try self.reapEligible(now: now)
        }
    }
    private func reapEligible(now: UInt64) throws {
        for name in Array(removedAt.keys).sorted() {
            guard let at = removedAt[name], now >= at, now - at >= retentionNS[name, default: UInt64.max], !playlist.contains(name), currentManifest != name, !leases.values.contains(where: { $0.name == name }), let file = files[name] else { continue }
            var st = stat(); try syscall(fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW), "retired stat"); try check(st, file)
            try syscall(unlinkat(directoryFD, name, 0), "retention-safe unlink")
            total -= file.size; files.removeValue(forKey: name); removedAt.removeValue(forKey: name)
            addHistory(["event":"retiredPayloadDeleted", "name":name, "clockNS":String(now), "removedAtNS":String(at), "requiredRetentionNS":String(retentionNS[name, default:0])]); retentionNS.removeValue(forKey:name)
        }
    }
    func reap(stamp s: BridgeStamp) async throws { try await perform { try self.validate(s); try self.reapEligible(now:self.monotonicNS()) } }
    // Reserve a maximum GOP plus one manifest; a full store stalls import/credit, never deletes early.
    static func canImport(total:Int,hasPending:Bool,fileCount:Int)->Bool {
        !hasPending && fileCount<62 && total<=aggregateCap-payloadCap-4096
    }
    func hasImportCapacity(stamp s: BridgeStamp) async throws -> Bool {
        try await perform {
            try self.validate(s); try self.reapEligible(now:self.monotonicNS())
            return Self.canImport(total:self.total,hasPending:self.pending != nil,fileCount:self.files.count)
        }
    }
    func publicationHistory() async throws -> [[String:String]] { try await perform { self.history } }
    func acquire(stamp s: BridgeStamp, name: String) async throws -> UUID {
        try await perform {
            try self.validate(s)
            let resolved = name == "index.m3u8" ? self.currentManifest ?? "unpublished" : name
            guard let f = self.files[resolved] else { throw MKVStoreError.rejected("unpublished") }
            try self.require(self.leases.count < Self.leaseCap, "lease cap")
            let fd = openat(self.directoryFD, resolved, O_RDONLY | O_NOFOLLOW); try self.syscall(fd, "lease open")
            var st = stat()
            do { try self.syscall(fstat(fd, &st), "lease stat"); try self.check(st, f) } catch { close(fd); throw error }
            let id = UUID(); self.leases[id] = Lease(fd: fd, size: f.size, name: resolved); self.leaseHigh = max(self.leaseHigh, self.leases.count); return id
        }
    }
    func leaseSize(id: UUID) async throws -> Int { try await perform { guard let l = self.leases[id] else { throw MKVStoreError.rejected("lease absent") }; return l.size } }
    private func check(_ st: stat, _ f: File) throws {
        try require((st.st_mode & S_IFMT) == S_IFREG && st.st_dev == f.device && st.st_ino == f.inode && st.st_size == f.size, "owned inode changed")
    }
    func read(lease id: UUID, offset: Int, count: Int) async throws -> MKVStoreReply {
        try await perform {
            guard let l = self.leases[id] else { throw MKVStoreError.rejected("lease absent") }
            try self.require(offset >= 0 && count > 0 && count <= Self.responseCap && offset <= l.size && count <= l.size - offset && count <= Self.responseCap - self.responseBytes, "response bounds")
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { pread(l.fd, $0.baseAddress!, count, off_t(offset)) }
            try self.require(n == count, "short response")
            let token = UUID(); self.replies[token] = (id, count); self.responseBytes += count; self.responseHigh = max(self.responseHigh, self.responseBytes)
            return MKVStoreReply(id: token, data: data)
        }
    }
    func releaseReply(id: UUID) async throws {
        try await perform { guard let r = self.replies.removeValue(forKey: id) else { throw MKVStoreError.rejected("reply absent") }; self.responseBytes -= r.1 }
    }
    func closeLease(id: UUID) async throws {
        try await perform {
            try self.require(!self.replies.values.contains { $0.0 == id }, "reply still borrowed")
            guard let l = self.leases.removeValue(forKey: id) else { throw MKVStoreError.rejected("lease absent") }; try self.syscall(close(l.fd), "lease close")
        }
    }
    func beginRetirement(stamp s: BridgeStamp) async throws {
        try await perform {
            try self.validate(s, active: false); self.retiring = true
            if self.pending != nil { try self.syscall(unlinkat(self.directoryFD, ".pending", 0), "discard unpublished stage"); self.pending = nil }
        }
    }
    func acknowledgeDrain(_ ack: BridgeDrainAck) async throws {
        try await perform { try self.validate(ack.stamp, active: false); try self.require(self.retiring && ack.fullyAcknowledged, "incomplete source/owner drain"); self.drained = true }
    }
    func cleanup(stamp s: BridgeStamp) async throws -> Bool {
        try await perform {
            try self.validate(s, active: false)
            guard self.retiring && self.drained && self.leases.isEmpty && self.replies.isEmpty else { return false }
            for (name, file) in self.files { var st = stat(); try self.syscall(fstatat(self.directoryFD, name, &st, AT_SYMLINK_NOFOLLOW), "cleanup stat"); try self.check(st, file) }
            for name in self.files.keys { try self.syscall(unlinkat(self.directoryFD, name, 0), "owned unlink") }
            try self.syscall(unlinkat(self.parentFD, self.name, AT_REMOVEDIR), "owned rmdir")
            close(self.directoryFD); close(self.parentFD); self.directoryFD = -1; self.parentFD = -1; self.cleaned = true; return true
        }
    }
    func snapshot() async throws -> MKVStoreSnapshot {
        try await perform { MKVStoreSnapshot(retiring: self.retiring, cleaned: self.cleaned, published: self.files.keys.sorted(), playlist: self.playlist, liveLeases: self.leases.count, responseBytes: self.responseBytes, drainAcknowledged: self.drained, pendingHighWater: self.pendingHigh, publishedHighWater: self.publishedHigh, responseHighWater: self.responseHigh, leaseHighWater: self.leaseHigh) }
    }
    deinit { for lease in leases.values { close(lease.fd) }; if directoryFD >= 0 { close(directoryFD) }; if parentFD >= 0 { close(parentFD) } }
}

#endif

#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation
@preconcurrency import Network

// All server bookkeeping on MainActor; file IO is exclusively on store queue.
@MainActor final class MKVLoopbackServer {
    let store: MKVSegmentStore, stamp: BridgeStamp
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false, serving = false
    private var startupCompleted = false
    private var responseTasks = 0, requests = 0, bytesSent = 0, sendCompletions = 0, socketTerminals = 0
    private var trace: [[String: Any]] = []
    var onObservation: ((MKVHTTPObservation)->Void)?
    private var observations:[UUID:MKVHTTPObservation]=[:]
    private func finishObservation(_ id:UUID,outcome:Int) {
        guard var value=observations.removeValue(forKey:id) else{return}
        value.completed=ProcessInfo.processInfo.systemUptime;value.outcome=value.timedOut ? 4:outcome
        onObservation?(value)
    }
    init(store: MKVSegmentStore, stamp: BridgeStamp) { self.store = store; self.stamp = stamp }
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: parameters); listener = l
        l.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        return try await withCheckedThrowingContinuation { continuation in
            l.stateUpdateHandler = { state in Task { @MainActor in
                guard !self.startupCompleted else { return }
                switch state {
                case .ready: self.startupCompleted = true; if let port = l.port { continuation.resume(returning: port.rawValue) } else { continuation.resume(throwing: MKVPlaybackError.failure("no port")) }
                case .failed(let error): self.startupCompleted = true; continuation.resume(throwing: error)
                case .cancelled: self.startupCompleted = true; continuation.resume(throwing: MKVPlaybackError.failure("listener cancelled"))
                default: break
                }
            } }
            l.start(queue: .main)
            Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); if !self.startupCompleted { self.startupCompleted = true; l.cancel(); continuation.resume(throwing: MKVPlaybackError.failure("listener deadline")) } }
        }
    }
    private func accept(_ c: NWConnection) {
        guard !stopped, connections.count < 4, requests < 1_000_000 else { c.cancel(); return }
        requests += 1; let id = UUID(); connections[id] = c
        observations[id]=MKVHTTPObservation(sequence:requests,accepted:ProcessInfo.processInfo.systemUptime)
        c.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            switch state { case .cancelled, .failed: if self?.connections.removeValue(forKey: id) != nil { self?.socketTerminals += 1 }; self?.timers.removeValue(forKey: id)?.cancel();self?.finishObservation(id,outcome:2); default: break }
        } }
        c.start(queue: .main)
        timers[id] = Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { self.observations[id]?.timedOut=true;c.cancel() } }
        receive(c, id: id, accumulated: Data())
    }
    private func receive(_ c: NWConnection, id: UUID, accumulated: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096 - accumulated.count) { [weak self] data, _, done, error in Task { @MainActor in
            guard let self, !self.stopped, self.connections[id] != nil else { return }
            var request = accumulated; if let data { request.append(data) }
            if error != nil || request.count > 4096 { c.cancel(); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.responseTasks += 1
                Task { @MainActor in await self.respond(c, id: id, request: request); self.responseTasks -= 1 }
            } else if !done && request.count < 4096 { self.receive(c, id: id, accumulated: request) } else { c.cancel() }
        } }
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                Task { @MainActor in self.sendCompletions += 1; if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            })
        }
    }
    private func respond(_ c: NWConnection, id: UUID, request: Data) async {
        var lease: UUID?, reply: MKVStoreReply?
        var acquiredTurn = false
        var outcome=3
        do {
            // Serialize complete responses, bounding outstanding store reply Data to16KiB.
            while serving && !stopped && connections[id] != nil { try await Task.sleep(nanoseconds: 2_000_000) }
            try mkvRequire(!stopped && connections[id] != nil, "server stopped")
            serving = true; acquiredTurn = true
            observations[id]?.serving=ProcessInfo.processInfo.systemUptime
            let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            let fields = (lines.first ?? "").split(separator: " ")
            try mkvRequire(fields.count == 3 && ["GET", "HEAD"].contains(String(fields[0])) && fields[1].first == "/", "request syntax")
            let name = String(fields[1].dropFirst())
            try mkvRequire(["init.mp4", "index.m3u8"].contains(name) || MKVSegmentStore.validName(name, prefix: "segment-", suffix: ".m4s"), "path whitelist")
            observations[id]?.kind = name == "index.m3u8" ? 1:name == "init.mp4" ? 2:3
            if name.hasPrefix("segment-") {observations[id]?.segment=Int(name.dropFirst(8).dropLast(4)) ?? 0}
            lease = try await store.acquire(stamp: stamp, name: name)
            let size = try await store.leaseSize(id: lease!)
            var low = 0, high = size - 1, partial = false
            let ranges = lines.filter { $0.lowercased().hasPrefix("range:") }
            if !ranges.isEmpty {
                try mkvRequire(ranges.count == 1, "range count")
                let spec = ranges[0].dropFirst(6).trimmingCharacters(in: .whitespaces)
                try mkvRequire(spec.hasPrefix("bytes=") && !spec.contains(","), "range syntax")
                let pair = spec.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard pair.count == 2, let first = Int(pair[0]), first >= 0, first < size else { throw MKVPlaybackError.failure("range start") }
                low = first
                if !pair[1].isEmpty { guard let last = Int(pair[1]), last >= low else { throw MKVPlaybackError.failure("range end") }; high = min(high, last) }; partial = true
            }
            let count = high - low + 1
            observations[id]?.low=low;observations[id]?.high=high
            try mkvRequire(count > 0 && bytesSent <= Int.max - count, "response lifetime byte cap")
            let type = name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
            let range = partial ? "Content-Range: bytes \(low)-\(high)/\(size)\r\n" : ""
            let header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\n\(range)Connection: close\r\nCache-Control: no-store\r\n\r\n"
            try await send(Data(header.utf8), connection: c)
            if fields[0] != "HEAD" {
                var offset = low
                while offset <= high {
                    try mkvRequire(!stopped, "stopped response")
                    reply = try await store.read(lease: lease!, offset: offset, count: min(16_384, high - offset + 1))
                    let token = reply!.id, length = reply!.data.count
                    try await send(reply!.data, connection: c) // completion, not enqueue, ends borrowed send.
                    if observations[id]?.firstPayload == nil {observations[id]?.firstPayload=ProcessInfo.processInfo.systemUptime}
                    observations[id]?.bytes += length
                    reply = nil; try await store.releaseReply(id: token)
                    offset += length; bytesSent += length
                }
            }
            if trace.count < 128 { trace.append(["path": name, "status": partial ? 206 : 200, "bytes": count, "sendCompletionReached": true]) }
            outcome=1
        } catch { if trace.count < 128 { trace.append(["status": "rejectedOrFailed", "reason": String(describing: error)]) } }
        if let held = reply { let token = held.id; reply = nil; try? await store.releaseReply(id: token) }
        if let lease { try? await store.closeLease(id: lease) }
        finishObservation(id,outcome:outcome);c.cancel(); if acquiredTurn { serving = false }
    }
    func stop() async -> [String: Any] {
        stopped = true; listener?.cancel(); listener?.newConnectionHandler = nil
        for c in connections.values { c.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while (responseTasks > 0 || !connections.isEmpty) && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        for t in timers.values { t.cancel() }; timers.removeAll()
        return ["responseTasksReturned": responseTasks == 0, "socketTerminalCallbacksObserved": connections.isEmpty, "remainingResponseTasks": responseTasks, "remainingConnections": connections.count, "sendCompletions": sendCompletions, "socketTerminalCount": socketTerminals, "requests": requests, "servedBytes": bytesSent, "trace": trace, "kernelTeardownProven": false]
    }
}

#endif

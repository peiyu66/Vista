import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

#if VISTA_SEEK_CHUNK_1M
struct SeekChunk215PolicyTests {
    let mib: UInt64 = 1_048_576
    @Test func successiveSeekAndStaleCompletion() {
        var sizing = SeekChunkSizing()
        let first = UUID(), second = UUID()
        #expect(sizing.limit(normal: 2*mib) == 2*mib)
        sizing.begin(first)
        #expect(sizing.limit(normal: 2*mib) == mib)
        sizing.begin(second)
        sizing.frame(first, paused: false); sizing.cancel(first); sizing.resume()
        #expect(sizing.seek == second && sizing.limit(normal: 2*mib) == mib)
        sizing.frame(second, paused: false)
        #expect(sizing.seek == nil && sizing.limit(normal: 2*mib) == 2*mib)
    }
    @Test func pausedPreviewDoesNotResumeLargeReadsUntilResume() {
        var sizing = SeekChunkSizing(); let id = UUID()
        sizing.begin(id); sizing.resume()
        #expect(sizing.limit(normal: 2*mib) == mib) // resume before a frame is insufficient
        sizing.frame(id, paused: true)
        #expect(sizing.delivered && sizing.limit(normal: 2*mib) == mib)
        sizing.resume()
        #expect(sizing.limit(normal: 2*mib) == 2*mib)
        sizing.begin(UUID()); sizing.reset()
        #expect(sizing.limit(normal: 2*mib) == 2*mib)
    }
    @Test func exactContiguousRangesAcrossTransitionAndEOF() throws {
        for length in [0,1,65_536,1_048_575,1_048_577,7_340_123] {
            let plan = try MediaReadPlan(requestedOffset: 13,currentOffset: 19,
                requestedLength: length+6,toEnd: false,fileSize: UInt64(length+19))
            var sizing = SeekChunkSizing(); let id = UUID(); sizing.begin(id)
            var cursor = plan.range.lowerBound, pieces:[Range<UInt64>] = []
            while cursor < plan.range.upperBound {
                let next = sizing.range(cursor:cursor,end:plan.range.upperBound,normal:2*mib)
                #expect(next.lowerBound == cursor && !next.isEmpty)
                #expect(next.count <= (pieces.isEmpty ? Int(mib) : Int(2*mib)))
                pieces.append(next); cursor=next.upperBound
                sizing.frame(id,paused:false)
            }
            #expect(pieces.reduce(0){$0+$1.count} == length)
            #expect(cursor == plan.range.upperBound)
        }
        var sizing=SeekChunkSizing()
        let alreadyStarted=sizing.range(cursor:0,end:8*mib,normal:2*mib)
        sizing.begin(UUID())
        #expect(alreadyStarted == 0..<2*mib) // never split/reissue an active read
        #expect(sizing.range(cursor:alreadyStarted.upperBound,end:8*mib,normal:2*mib) == 2*mib..<3*mib)
        #expect(sizing.limit(normal:65_536) == 65_536)
    }
}

@MainActor private final class Seek215Source: MediaByteSource {
    let bytes:Data
    var ranges:[Range<UInt64>] = []
    init(_ data:Data) { bytes=data }
    func fileSize(for file:MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
    func read(_ file:MediaFile,range:Range<UInt64>) async throws -> Data {
        ranges.append(range)
        try await Task.sleep(for:.milliseconds(3))
        try Task.checkCancellation()
        return bytes.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}

@Suite(.serialized) @MainActor struct SeekChunk215IntegrationTests {
    enum Failure:Error {case timeout}
    func until(_ condition:()->Bool) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(12))
        while !condition() {
            guard ContinuousClock.now<end else {throw Failure.timeout}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    @Test func cacheBytesRemainCorrectWhenDemandChangesSize() async throws {
        let file=try MediaFile(components:["synthetic.mp4"]),mib=1_048_576
        let data=Data((0..<(5*mib)).map{UInt8($0 % 251)})
        let source=Seek215Source(data)
        let identity=PlaybackSourceIdentity(size:UInt64(data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
        let recovering=PlaybackRecoveringSource(file:file,initial:source,metadata:{_,_ in identity},
            makeFresh:{throw Failure.timeout},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
        let cache=PlaybackPrefetchSource(file:file,source:recovering)
        _=try await cache.fileSize(for:file)
        cache.setPrefetchEnabled(false,reason:.seek)
        let large=try await cache.read(file,range:0..<UInt64(2*mib))
        #expect(large==data.prefix(2*mib))
        let calls=source.ranges.count
        let one=try await cache.read(file,range:0..<UInt64(mib))
        let two=try await cache.read(file,range:UInt64(mib)..<UInt64(2*mib))
        #expect(one+two==large && source.ranges.count==calls)
        let partial=try await cache.read(file,range:UInt64(3*mib/2)..<UInt64(5*mib/2))
        #expect(partial==data.subdata(in:3*mib/2..<5*mib/2))
        let normal=try await cache.read(file,range:UInt64(mib)..<UInt64(3*mib))
        #expect(normal==data.subdata(in:mib..<3*mib))
        let eof=try await cache.read(file,range:UInt64(5*mib-17)..<UInt64(5*mib))
        #expect(eof==data.suffix(17))
        cache.cancelPlayback();try await cache.awaitPlaybackCleanup()
    }
    @Test func bridgeSourceIsolationCancelAndStop() async throws {
        let file=try MediaFile(components:["synthetic.mp4"])
        let source=Seek215Source(Data(count:16))
        let first=ResourceBridge(source:source,file:file,size:16,contentType:"public.mpeg-4",chunkBytes:2_097_152)
        let next=ResourceBridge(source:source,file:file,size:16,contentType:"public.mpeg-4",chunkBytes:2_097_152)
        let a=UUID(),b=UUID()
        first.beginSeekChunks(a);first.beginSeekChunks(b);first.cancelSeekChunks(a)
        #expect(first.currentDemandChunkLimit==1_048_576)
        #expect(next.currentDemandChunkLimit==2_097_152)
        first.cancelSeekChunks(b)
        #expect(first.currentDemandChunkLimit==2_097_152)
        first.beginSeekChunks(a);await first.stop()
        #expect(first.currentDemandChunkLimit==2_097_152)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SEEK215_FIXTURE"] != nil))
    func realAVPlayerTransitionsAndChunkJournal() async throws {
        let path=try #require(ProcessInfo.processInfo.environment["VISTA_SEEK215_FIXTURE"])
        let data=try Data(contentsOf:URL(fileURLWithPath:path))
        #expect(data.count>16*1_048_576)
        let source=Seek215Source(data),native=NativePlaybackSession(stallLimit:8,muted:true)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vista-seek215-"+UUID().uuidString)
        let writer=LifecycleDiagnostics(directory:dir,fileLimit:4_194_304,pendingLimit:2048,mirror:false,criticalDurability:false)
        native.mp4SeekWriterForTesting=writer
        var frames=0, sessions:Set<UUID>=[]
        let task=Task {try await native.play(file:MediaFile(components:["generated.mp4"]),source:source,
            onInfo:{_ in},onState:{_ in},onFrame:{f in
                frames+=1;sessions.insert(f.session);native.recordPresentation(session:f.session)
            })}
        do {
            try await until{frames>=2}
            #expect(native.experimentCurrentDemandChunkLimit==2_097_152)
            let before=sessions.count
            let seek=Task{try await native.seek(to:24,maximumBackward:0)}
            try await until{native.experimentCurrentDemandChunkLimit==1_048_576}
            #expect(native.anonymousLogValues()[.currentDemandChunkBytes]==1_048_576)
            try await seek.value
            try await until{sessions.count>before}
            #expect(native.experimentCurrentDemandChunkLimit==2_097_152)
            #expect(native.anonymousLogValues()[.currentDemandChunkBytes]==2_097_152)
            native.pause()
            let count=sessions.count
            let old=Task{try await native.seek(to:4,maximumBackward:0)}
            await Task.yield()
            let latest=Task{try await native.seek(to:12,maximumBackward:0)}
            _=try? await old.value;try await latest.value
            #expect(native.isPlaybackPaused)
            #expect(native.experimentCurrentDemandChunkLimit==1_048_576)
            native.resume()
            try await until{sessions.count>count && native.experimentCurrentDemandChunkLimit==2_097_152}
            native.stop();task.cancel();_=try? await task.value
            writer.drainForTesting()
            let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.pathExtension=="jsonl"}
            let rows=try files.flatMap{try Data(contentsOf:$0).split(separator:10).map{try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]}}
            let fields=rows.compactMap{$0["fields"] as? [String:Double]}
            let starts=fields.filter{$0["phase"]==20}
            #expect(!starts.isEmpty)
            #expect(starts.allSatisfy{($0["rangeUpper"]!-$0["rangeLower"]!)<=1_048_576})
            #expect(starts.contains{($0["rangeUpper"]!-$0["rangeLower"]!)==1_048_576})
            #expect(fields.contains{$0["phase"]==11 && $0["bytes"]==1_048_576 && $0["detail"]==1})
            #expect(fields.contains{$0["phase"]==11 && $0["bytes"]==2_097_152 && $0["detail"]==2})
            #expect(writer.status.dropped==0 && writer.status.writerFailures==0)
            print("SEEK215_AVPLAYER", "rows", rows.count, "chunks",starts.count,"journal",dir.path)
        } catch {
            native.stop();task.cancel();_=try? await task.value;throw error
        }
    }
}
#endif

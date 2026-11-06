import Foundation
@preconcurrency import AVFoundation

struct AudioSample: @unchecked Sendable { let buffer: CMSampleBuffer }

private final class AudioObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    func clear() { tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll() }
    deinit { clear() }
}

/// Main-actor owner of the output device clock. Video reads this same clock.
@MainActor final class PlaybackAudioClock {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let observers = AudioObservers()
    private var stopped = false
    private var stopReason = PlaybackDiagnosticStage.audioStopped
    private var started = false
    private var sessionActive = false
    private let startTime: CMTime
    init(muted: Bool, startAt: Double = 0) {
        startTime = CMTime(seconds: startAt, preferredTimescale: 60_000)
        renderer.isMuted = muted
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(0, time: startTime)
        observe(.AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, reason: .audioFlushed)
        observe(.AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer, reason: .audioConfiguration)
        #if os(visionOS)
        observe(AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), reason: .audioInterruption)
        #endif
    }
    private func observe(_ name: Notification.Name, object: AnyObject, reason: PlaybackDiagnosticStage) {
        observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop(reason: reason) }
        })
    }
    var time: Double { synchronizer.currentTime().seconds }
    var hasStarted:Bool {started && !stopped}
    func enqueue(_ sample: AudioSample) throws -> Bool {
        try check()
        guard renderer.isReadyForMoreMediaData else { return false }
        renderer.enqueue(sample.buffer)
        try check()
        return true
    }
    func check() throws {
        guard !stopped else { throw PlaybackFailure.audioFailed.diagnosed(stopReason) }
        guard renderer.status != .failed else { throw PlaybackFailure.audioFailed.diagnosed(.audioRenderer, status: (renderer.error as NSError?)?.code) }
    }
    func start() throws {
        try check()
        guard !started else { return }
        #if os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            sessionActive = true
        } catch { throw PlaybackFailure.audioFailed.diagnosed(.audioSession, status: (error as NSError).code) }
        #endif
        started = true
        synchronizer.setRate(1, time: startTime)
    }
    func pause() { if started { synchronizer.rate = 0 } }
    func resume() { if started && !stopped { synchronizer.rate = 1 } }
    func stop(reason: PlaybackDiagnosticStage = .audioStopped) {
        guard !stopped else { return }
        stopReason = reason
        stopped = true
        observers.clear()
        synchronizer.rate = 0
        renderer.flush()
        #if os(visionOS)
        if sessionActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        sessionActive = false
    }
}

/// Decodes only audio to bounded PCM buffers; this never supplies a video decoder.
actor AudioPlayback {
    let clock: PlaybackAudioClock
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: AudioSample?
    private var decodedFormat: CMFormatDescription?
    private var previousEnd = -Double.infinity
    private var reachedEnd = false
    private(set) var sampleCount = 0
    init(asset: AVAsset, track: AVAssetTrack, clock: PlaybackAudioClock, startAt: Double = 0) throws {
        self.clock = clock
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw PlaybackFailure.audioFailed.diagnosed(.audioReaderCreate, status: (error as NSError).code) }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startAt, preferredTimescale: 60_000), duration: .positiveInfinity)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PlaybackFailure.audioFailed.diagnosed(.audioReaderAdd) }
        reader.add(output)
        guard reader.startReading() else { throw PlaybackFailure.audioFailed.diagnosed(.audioReaderStart, status: (reader.error as NSError?)?.code) }
    }
    static func supported(_ format: CMAudioFormatDescription) -> Bool {
        guard let info = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
        return [kAudioFormatMPEG4AAC, kAudioFormatLinearPCM].contains(info.mFormatID)
            && (1...2).contains(info.mChannelsPerFrame)
            && info.mSampleRate.isFinite && (8_000...48_000).contains(info.mSampleRate)
    }
    /// At most half a second ahead plus one bounded packet. No whole-track PCM accumulation.
    func pump(through horizon: Double) async throws {
        try Task.checkCancellation()
        try await clock.check()
        while !reachedEnd {
            try Task.checkCancellation()
            if pending == nil {
                guard let buffer = output.copyNextSampleBuffer() else {
                    guard reader.status == .completed else { throw PlaybackFailure.audioFailed.diagnosed(.audioReaderEnd, status: (reader.error as NSError?)?.code) }
                    reachedEnd = true
                    break
                }
                let start = CMSampleBufferGetOutputPresentationTimeStamp(buffer).seconds
                let duration = CMSampleBufferGetDuration(buffer).seconds
                let bytes = CMSampleBufferGetTotalSampleSize(buffer)
                guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 0.25,
                      start + 0.001 >= previousEnd, bytes > 0, bytes <= 192_000,
                      let format = CMSampleBufferGetFormatDescription(buffer),
                      CMFormatDescriptionGetMediaSubType(format) == kAudioFormatLinearPCM,
                      Self.supported(format) else { throw PlaybackFailure.audioFailed.diagnosed(.audioPacket) }
                if let decodedFormat, !CMFormatDescriptionEqual(decodedFormat, otherFormatDescription: format) {
                    throw PlaybackFailure.audioFailed.diagnosed(.audioFormatChanged)
                }
                decodedFormat = format
                previousEnd = start + duration
                pending = AudioSample(buffer: buffer)
            }
            guard let sample = pending else { break }
            if CMSampleBufferGetOutputPresentationTimeStamp(sample.buffer).seconds > horizon { break }
            guard try await clock.enqueue(sample) else { break }
            sampleCount += CMSampleBufferGetNumSamples(sample.buffer)
            pending = nil
        }
    }
    func stop() async { reader.cancelReading(); pending = nil; await clock.stop() }
}

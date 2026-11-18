@MainActor final class ShortcutInputLog {
    static let shared=ShortcutInputLog()
    private let writer:LifecycleDiagnostics
    private var capture=0
    init(directory:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VistaShortcutDiagnostics",isDirectory:true)) {
        writer=LifecycleDiagnostics(directory:directory,mirror:false,criticalDurability:false)
    }
    func persist(_ e:ShortcutInputMemoryProbe.Event) {
        if e.kind == .captureStarted {capture += 1}
        let kinds:[ShortcutInputMemoryProbe.Kind]=[.changed,.ended,.inactive,.rowDisappeared,.scroll,.cleared,.editingChanged,.browserDisappeared,.captureStarted,.captureStopped,.orderResult,.highlightActive]
        var f:[LifecycleField:Double]=[.scope:212,.capture:Double(capture),.inputKind:Double(kinds.firstIndex(of:e.kind)!+1),.row:Double(e.row),.firstSequence:Double(e.firstSequence),.lastSequence:Double(e.lastSequence),.firstMS:e.firstMS,.lastMS:e.lastMS,.sampleCount:Double(e.count)]
        if let v=e.firstOffset {f[.firstOffset]=v};if let v=e.offset {f[.offset]=v}
        if let c=e.context {
            f[.ordinal]=Double(c.ordinal);f[.inputX]=c.x;f[.inputY]=c.y;f[.offset]=c.offset;f[.contentHeight]=c.contentHeight
            f[.about]=c.about ? 1:0;f[.removing]=c.removing ? 1:0;f[.playback]=c.playback ? 1:0
            if c.rowRect.count==4 {f[.rowX]=c.rowRect[0];f[.rowY]=c.rowRect[1];f[.rowWidth]=c.rowRect[2];f[.rowHeight]=c.rowRect[3]}
            if c.viewport.count==2 {f[.viewportWidth]=c.viewport[0];f[.viewportHeight]=c.viewport[1]}
        }
        if let c=e.firstContext {f[.firstX]=c.x;f[.firstY]=c.y;f[.firstOffset]=c.offset}
        if let o=e.order {f[.orderOutcome]=Double(o.outcome.rawValue);f[.fromOrdinal]=Double(o.from);f[.requestedOrdinal]=Double(o.requested);f[.appliedOrdinal]=Double(o.applied)}
        // 0 means unavailable, never "not focused" or "no attempt".
        f[.gazeObservable]=0;f[.physicalAttemptObservable]=0
        f[.handleFrame]=44;f[.targetDiameter]=36;f[.targetInset]=4
        writer.record(.shortcutInput,f)
    }
}

import Foundation
// Non-observable bounded capture. The injected sink uses the existing asynchronous diagnostic writer; no gesture recognizers or timers.
@MainActor final class ShortcutInputMemoryProbe {
    static let shared = ShortcutInputMemoryProbe(sink:ShortcutInputLog.shared.persist)
    enum Kind:String,Codable { case changed, ended, inactive, rowDisappeared, scroll, cleared, editingChanged, browserDisappeared, captureStarted, captureStopped, orderResult, highlightActive }
    struct Context:Codable,Equatable {
        var row:Int
        var ordinal:Int
        var x:Double
        var y:Double
        var rowRect:[Double]
        var viewport:[Double]
        var offset:Double
        var contentHeight:Double
        var about:Bool
        var removing:Bool
        var playback:Bool
    }
    enum OrderOutcome:Int,Codable {case noInsertion=1,notEditing,storageUnavailable,savedChanged,savedUnchanged,saveFailed}
    struct OrderResult:Codable {let outcome:OrderOutcome;let from:Int;let requested:Int;let applied:Int}
    struct Event:Codable {
        var firstSequence:Int
        var lastSequence:Int
        var firstMS:Double
        var lastMS:Double
        var kind:Kind
        var row:Int
        var count:Int
        var firstContext:Context?
        var context:Context?
        var firstOffset:Double?
        var offset:Double?
        var order:OrderResult?
    }
    struct Report:Codable {
        let schema:Int
        let recording:Bool
        let observations:Int
        let discardedGroups:Int
        let aliasCapacityReached:Bool
        let events:[Event]
        let limits:String
    }
    private(set) var recording=false
    private(set) var events:[Event]=[]
    private(set) var observations=0
    private(set) var discardedGroups=0
    private(set) var aliasCapacityReached=false
    private var aliases:[UUID:Int]=[:]
    private var contexts:[Int:Context]=[:]
    private var started=0.0
    private let clock:()->Double
    private let capacity=128
    private let sink:@MainActor (Event)->Void
    private var persistedSequence=0
    init(clock:@escaping ()->Double = {ProcessInfo.processInfo.systemUptime},sink:@escaping @MainActor (Event)->Void = {_ in}) { self.clock=clock;self.sink=sink }
    func begin() {
        stop()
        events.removeAll(keepingCapacity:true);aliases.removeAll(keepingCapacity:true);contexts.removeAll(keepingCapacity:true)
        observations=0;discardedGroups=0;aliasCapacityReached=false;started=clock();persistedSequence=0;recording=true
        append(.captureStarted,row:0,context:nil,offset:nil)
    }
    func stop() {
        guard recording else{return}
        append(.captureStopped,row:0,context:nil,offset:nil);recording=false
    }
    func editing(_ active:Bool) {if active {if !recording {begin()}} else {stop()}}
    func order(id:UUID,outcome:OrderOutcome,from:Int,requested:Int,applied:Int) {
        guard recording else{return}
        let row=alias(id)
        append(.orderResult,row:row,context:contexts[row],offset:nil,order:OrderResult(outcome:outcome,from:from,requested:requested,applied:applied))
    }
    private func flushLast() {
        guard let last=events.last,last.lastSequence>persistedSequence else{return}
        sink(last);persistedSequence=last.lastSequence
    }
    private func alias(_ id:UUID)->Int {
        if let value=aliases[id] {return value}
        guard aliases.count<capacity else {aliasCapacityReached=true;return 0}
        let value=aliases.count+1;aliases[id]=value;return value
    }
    func input(_ kind:Kind,id:UUID,ordinal:Int,point:CGPoint,rect:CGRect?,viewport:CGSize,offset:Double,contentHeight:Double,about:Bool,removing:Bool,playback:Bool) {
        guard recording else{return}
        let row=alias(id)
        let context=Context(row:row,ordinal:ordinal,x:point.x,y:point.y,
            rowRect:rect.map{[$0.minX,$0.minY,$0.width,$0.height]} ?? [],
            viewport:[viewport.width,viewport.height],offset:offset,contentHeight:contentHeight,
            about:about,removing:removing,playback:playback)
        if row != 0 {contexts[row]=context}
        append(kind,row:row,context:context,offset:nil)
    }
    func highlight(_ active:Bool,id:UUID) {
        guard recording else{return}
        if active {let row=alias(id);append(.highlightActive,row:row,context:contexts[row],offset:nil)}
        else {lifecycle(.inactive,id:id)}
    }
    func lifecycle(_ kind:Kind,id:UUID) {
        guard recording,let row=aliases[id] else{return}
        // This is an observed inactive/disappear edge, never a claim of OS cancellation.
        append(kind,row:row,context:contexts[row],offset:nil)
    }
    func scroll(offset:Double) {
        guard recording else{return}
        append(.scroll,row:0,context:nil,offset:offset)
    }
    func boundary(_ kind:Kind,active:UUID?=nil) {
        guard recording else{return}
        let row=active.flatMap{aliases[$0]} ?? 0
        append(kind,row:row,context:contexts[row],offset:nil)
    }
    private func append(_ kind:Kind,row:Int,context:Context?,offset:Double?,order:OrderResult?=nil) {
        observations += 1
        let ms=(clock()-started)*1000
        // Compress only consecutive updates. Start/end/inactive boundaries stay separate.
        if (kind == .changed || kind == .scroll),var last=events.last,last.kind==kind,last.row==row {
            last.lastSequence=observations;last.lastMS=ms;last.count += 1;last.context=context;last.offset=offset
            events[events.count-1]=last;return
        }
        flushLast()
        if events.count==capacity {events.removeFirst();discardedGroups += 1}
        events.append(Event(firstSequence:observations,lastSequence:observations,firstMS:ms,lastMS:ms,kind:kind,row:row,count:1,firstContext:context,context:context,firstOffset:offset,offset:offset,order:order))
        if kind != .changed && kind != .scroll {flushLast()}
    }
    func snapshot()->String {
        let report=Report(schema:1,recording:recording,observations:observations,discardedGroups:discardedGroups,aliasCapacityReached:aliasCapacityReached,events:events,
            limits:"Observed SwiftUI callbacks only. inactive is not proof of cancellation; onEnded ordering may vary. Missing callbacks cannot count attempted pinches or identify the winning recognizer. Context at inactive/disappear is the last input sample, not a fresh geometry measurement. Consecutive changed/scroll updates retain only first/last samples and count. Diagnostic sink persists completed groups asynchronously; an unflushed tail or pending writes can be lost at process exit. Gaze focus and unreported physical pinch attempts are unknown.")
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        guard let data=try? encoder.encode(report),let text=String(data:data,encoding:.utf8) else{return "Snapshot encoding failed"}
        return text
    }
}

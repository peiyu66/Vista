import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB

struct FinderTagTests {
    func plist(_ value:Any)throws->Data {try PropertyListSerialization.data(fromPropertyList:value,format:.binary,options:0)}
    @Test func parsesNamesAndColorsForAccessibleInitials()throws {
        let state=FinderTagParser.parse(try plist(["Private A\n6","Private B\n4","Private C","Private D\n6"]))
        #expect(state.colors == [6,4,0]);#expect(state.label == "Private A、Private B、Private C、Private D")
        #expect(state.displayTags.map(\.initial) == ["P","P","P","P"])
        #expect(FinderTagParser.parse(try plist([String]())) == .loaded([]))
    }
    @Test func rejectsMalformedOversizedAndUnexpectedTypes()throws {
        for value:Any in [["bad\n9"],["bad\n1\n2"],[""],Array(repeating:"tag",count:33),["key":"value"],[1,2]] {
            #expect(FinderTagParser.parse(try plist(value)) == .invalid)
        }
        #expect(FinderTagParser.parse(Data(repeating:0,count:20_000)) == .invalid)
        let good=try plist(["tag\n2"])
        for count in 0..<good.count {#expect(FinderTagParser.parse(good.prefix(count)) == .invalid)}
        var bad=good;bad.replaceSubrange((bad.count-24)..<(bad.count-16),with:Array(repeating:UInt8(255),count:8))
        #expect(FinderTagParser.parse(bad) == .invalid)
    }
    func entry(_ name:String,_ state:FinderTagState)->FileEntry {var value=FileEntry(name,.video);value.finderTags=state;return value}
    @Test func nameSortIsStableAndErrorsAreNeverEmpty() {
        let red=FinderTagState.loaded([FinderTag(name:"r",color:6)])
        let blue=FinderTagState.loaded([FinderTag(name:"b",color:4)])
        let mixed=FinderTagState.loaded([FinderTag(name:"b",color:4),FinderTag(name:"r",color:6)])
        let entries=[entry("blue",blue),entry("red",red),entry("mixed",mixed),entry("none",.loaded([])),entry("denied",.denied),entry("missing",.unavailable)]
        #expect(DirectorySort(field:.tags).sorted(entries).map(\.name)==["blue","mixed","red","none","missing","denied"])
        #expect(DirectorySort(field:.tags,ascending:false).sorted(entries).map(\.name)==["red","mixed","blue","none","missing","denied"])
        #expect(FinderTagState.unavailable.label != FinderTagState.loaded([]).label)
    }
    @Test func tenThousandEntriesRetainStableOrder() {
        let rows=(0..<10_000).map {entry(String(format:"%05d",$0),.loaded([FinderTag(name:"synthetic",color:$0%8)]))}
        let start=Date();let sorted=DirectorySort(field:.tags).sorted(rows)
        #expect(Set(sorted.map(\.id)).count==10_000)
        #expect(sorted.map(\.id) == rows.map(\.id))
        print("SYNTHETIC_TAG_SORT_10000_MS",Date().timeIntervalSince(start)*1000)
    }
    @Test func transportErrorsStayDistinct() {
        #expect(SMBDirectoryProvider.tagFailure(POSIXError(.ENOENT)) == .unavailable)
        #expect(SMBDirectoryProvider.tagFailure(POSIXError(.ENOTSUP)) == .unsupported)
        #expect(SMBDirectoryProvider.tagFailure(POSIXError(.EACCES)) == .denied)
        #expect(SMBDirectoryProvider.tagFailure(POSIXError(.EIO)) == .failed)
        #expect(SMBDirectoryProvider.tagFailure(URLError(.timedOut)) == .failed)
    }
    @Test func blankStatesDoNotEraseErrorMeaning() {
        #expect(FinderTagState.loaded([]).isVisuallyEmpty)
        #expect(FinderTagState.unavailable.isVisuallyEmpty)
        #expect(FinderTagState.loaded([]) != .unavailable)
        for state:FinderTagState in [.unsupported,.denied,.invalid,.failed,.loaded([FinderTag(name:"none",color:0)])] {#expect(!state.isVisuallyEmpty)}
    }
    @Test func initialsPreserveGraphemesAndFullNameSorting()throws {
        let state=FinderTagParser.parse(try plist(["Yellow\n0","Orange\n0","旅行\n0","旅遊\n6","👩🏽‍💻工作\n0","éclair\n4"]))
        #expect(Set(state.displayTags.map(\.initial)) == Set(["Y","O","旅","👩🏽‍💻","é"]))
        #expect(state.displayTags.filter{$0.initial == "旅"}.count==2)
        let rows=[entry("z",.loaded([FinderTag(name:"Office",color:6)])),entry("a",.loaded([FinderTag(name:"Orange",color:0)]))]
        #expect(DirectorySort(field:.tags).sorted(rows).map(\.name)==["z","a"])
        #expect(DirectorySort(field:.tags,ascending:false).sorted(rows).map(\.name)==["a","z"])
        let reversed=FinderTagState.loaded(state.displayTags.reversed())
        #expect(state.sortNames == reversed.sortNames)
    }
    @Test func compareInMemorySortCosts() {
        for count in [1_000,5_000,10_000] {
            let rows=(0..<count).map {index -> FileEntry in
                var row=FileEntry(String(format:"%05d",index),.video,modifiedAt:Date(timeIntervalSince1970:Double(count-index)))
                row.finderTags = .loaded([FinderTag(name:"synthetic",color:index%8)]);return row
            }
            for field in [DirectorySort.Field.modified,.tags] {
                let start=Date();let sorted=DirectorySort(field:field).sorted(rows)
                let ms=Date().timeIntervalSince(start)*1000
                #expect(sorted.count==count)
                print("SYNTHETIC_IN_MEMORY_SORT",count,field.rawValue,ms)
            }
        }
    }
    @Test func initiallyBlankDoesNotMeanProcessed() {
        for state:FinderTagState in [.notLoaded,.loading] {
            #expect(state.isVisuallyEmpty);#expect(!state.isResolvedForSorting)
        }
        #expect(FinderTagState.unavailable.isResolvedForSorting)
        #expect(!FinderTagState.unavailable.isConfirmed)
        let rows=[entry("b",.loaded([])),entry("a",.unavailable),entry("c",.loaded([]))]
        for ascending in [true,false] {#expect(DirectorySort(field:.tags,ascending:ascending).sorted(rows).map(\.name)==["b","c","a"])}
    }
    @Test func normalizedCombinationsIgnoreReadOrderButKeepFullNames() {
        let names=["Yellow","Orange","Office","旅行","旅遊","éclair"]
        let a=FinderTagState.loaded(names.map{FinderTag(name:$0,color:0)})
        let b=FinderTagState.loaded(names.reversed().map{FinderTag(name:$0.precomposedStringWithCanonicalMapping,color:6)})
        #expect(a.sortNames==b.sortNames)
        #expect(a.displayTags.map(\.name)==b.displayTags.map(\.name))
        #expect(a.displayTags.filter{$0.initial=="O"}.map(\.name)==["Office","Orange"])
        let rows=[entry("z",a),entry("a",b),entry("m",.loaded([FinderTag(name:"Other",color:0)]))]
        for ascending in [true,false] {
            let result=DirectorySort(field:.tags,ascending:ascending).sorted(rows).map(\.name)
            #expect(abs(result.firstIndex(of:"a")!-result.firstIndex(of:"z")!)==1)
        }
    }
    actor RequestCount {var streams=0;func read()throws->Data {streams += 1;throw POSIXError(.ENOENT)}}
    @Test func fiveThousandMissingStreamsUseOneAttemptEach()async {
        let counter=RequestCount()
        for _ in 0..<5_000 {
            let result=await SMBDirectoryProvider.readTagMetadata {try await counter.read()}
            #expect(result == .unavailable)
        }
        #expect(await counter.streams==5_000)
        print("SYNTHETIC_MISSING_STREAM_ATTEMPTS",await counter.streams)
        #expect(await SMBDirectoryProvider.readTagMetadata {throw POSIXError(.EACCES)} == .denied)
        #expect(await SMBDirectoryProvider.readTagMetadata {throw URLError(.networkConnectionLost)} == .failed)
        #expect(await SMBDirectoryProvider.readTagMetadata {Data([0,1])} == .invalid)
    }
    actor Counter {var active=0;var maximum=0;func enter(){active+=1;maximum=max(maximum,active)};func leave(){active-=1}}
    @Test func cancellationKeepsAdmissionUntilReadDrains()async throws {
        let gate=SMBTagAdmission(),counter=Counter()
        let first=Task {try await gate.read {await counter.enter();try? await Task.sleep(for:.milliseconds(120));await counter.leave();return .loaded([])}}
        while await counter.active==0 {try await Task.sleep(for:.milliseconds(1))}
        first.cancel()
        let second=Task {try await gate.read {await counter.enter();await counter.leave();return .unsupported}}
        do {_ = try await first.value;Issue.record("cancelled result published")}catch is CancellationError {}catch {Issue.record("unexpected error")}
        #expect(try await second.value == .unsupported);#expect(await counter.maximum==1);#expect(await counter.active==0)
    }
}

import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB

private actor ProbeCounts {
    var tags=0;var info=0
    func tag(_ state:FinderTagState)->FinderTagState {tags+=1;return state}
    func finder(_ valid:Bool)->Bool {info+=1;return valid}
    func counts()->[Int] {[tags,info]}
}
struct TagSupportTests {
    @Test func refreshInvalidatesOnlyImmediateMetadataChildren() {
        #expect(SMBDirectoryProvider.isImmediateChild("a/b.mp4",of:"a"))
        #expect(!SMBDirectoryProvider.isImmediateChild("a/sub/b.mp4",of:"a"))
        #expect(!SMBDirectoryProvider.isImmediateChild("ab/b.mp4",of:"a"))
        #expect(SMBDirectoryProvider.isImmediateChild("b.mp4",of:""))
    }

    @Test func policyCacheAndEndpointIdentity() throws {
        var source=SavedSource(kind:.smb,name:"same name",server:"NAS.local.",username:"test")
        #expect(!source.providesFinderTags)
        source.tagEvidenceEndpoint=TagSupportEvidence.endpoint("nas.local")
        #expect(source.providesFinderTags)
        source.tagPolicy = .disabled
        #expect(source.providesFinderTags)
        source.tagPolicy = .mac;source.server="different.example.test"
        #expect(!source.providesFinderTags)
        source.tagPolicy = .automatic
        #expect(!source.providesFinderTags)
        source.server="NAS.local"
        let roundtrip=try JSONDecoder().decode(SavedLocations.self,from:JSONEncoder().encode(SavedLocations(sources:[source])))
        #expect(roundtrip.sources[0].providesFinderTags)
        for policy in [TagSupportPolicy.mac,.disabled,.automatic] {
            var legacySource=source;legacySource.tagPolicy=policy
            let migrated=SavedLocations(sources:[legacySource]).migratedHosts()
            #expect(migrated.sources[0].tagPolicy == nil)
            #expect(migrated.sources[0].providesFinderTags)
            legacySource.tagEvidenceEndpoint=nil
            #expect(!SavedLocations(sources:[legacySource]).migratedHosts().sources[0].providesFinderTags)
        }
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as! [String:Any]
        legacy.removeValue(forKey:"tagPolicy");legacy.removeValue(forKey:"tagEvidenceEndpoint")
        let old=try JSONDecoder().decode(SavedSource.self,from:JSONSerialization.data(withJSONObject:legacy))
        #expect(!old.providesFinderTags)
        #expect(old.server==source.server && old.username==source.username && old.id==source.id)
        var renamed=roundtrip.sources[0];renamed.name="new display name";renamed.username="other user"
        #expect(renamed.providesFinderTags)
        renamed.tagEvidenceEndpoint=nil
        #expect(!renamed.providesFinderTags)
    }
    @Test func bonjourRequiresEndpointAndAppleDeclaration() {
        let model=["model":Data("Mac14,12".utf8)],version=["osxvers":Data("26".utf8)]
        #expect(TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"NAS.local.",port:445,txt:model))
        #expect(TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"nas.local",port:445,txt:version))
        #expect(!TagSupportEvidence.bonjour(server:"different.local",resolvedHost:"nas.local",port:445,txt:model))
        #expect(!TagSupportEvidence.bonjour(server:"100.64.0.1",resolvedHost:"nas.local",port:445,txt:model))
        #expect(!TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"nas.local",port:1445,txt:model))
        #expect(!TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"nas.local",port:445,txt:["model":Data("Generic NAS".utf8)]))
        #expect(!TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"nas.local",port:445,txt:["osxvers":Data("unknown".utf8)]))
        #expect(!TagSupportEvidence.bonjour(server:"nas.local",resolvedHost:"nas.local",port:445,txt:["model":Data("Mac compatible NAS".utf8)]))
    }
    @Test func onlyPositiveAppleMetadataCounts() {
        #expect(TagSupportEvidence.tags(.loaded([FinderTag(name:"A",color:0)])))
        for state:FinderTagState in [.loaded([]),.unavailable,.unsupported,.denied,.invalid,.failed] {
            #expect(!TagSupportEvidence.tags(state))
        }
        var valid=Data([0x41,0x46,0x50,0,0,0,1,0]+Array(repeating:UInt8(0),count:52))
        #expect(!TagSupportEvidence.finderInfo(valid))
        valid[16]=1
        #expect(TagSupportEvidence.finderInfo(valid))
        #expect(!TagSupportEvidence.finderInfo(valid.dropLast()))
        #expect(!TagSupportEvidence.finderInfo(valid+Data([0])))
        valid[0]=0
        #expect(!TagSupportEvidence.finderInfo(valid))
        #expect(!TagSupportEvidence.finderInfo(Data(repeating:1,count:32)))
    }
    @Test func samplesAreBoundedAndEmptyIsNotPermanentNegative() async throws {
        let counts=ProbeCounts()
        let found=try await SMBDirectoryProvider.probeFinderEvidence(paths:(0..<5000).map(String.init),readTags:{_ in await counts.tag(.loaded([]))},readInfo:{_ in await counts.finder(false)})
        #expect(!found);#expect(await counts.counts()==[3,3])
        let later=try await SMBDirectoryProvider.probeFinderEvidence(paths:["new"],readTags:{_ in .loaded([FinderTag(name:"Later",color:0)])},readInfo:{_ in false})
        #expect(later)
    }
    @Test func eitherMetadataSignalStopsEarly() async throws {
        let counts=ProbeCounts()
        #expect(try await SMBDirectoryProvider.probeFinderEvidence(paths:["a","b","c"],readTags:{_ in await counts.tag(.loaded([FinderTag(name:"Tag",color:0)]))},readInfo:{_ in await counts.finder(false)}))
        #expect(await counts.counts()==[1,0])
        let other=ProbeCounts()
        #expect(try await SMBDirectoryProvider.probeFinderEvidence(paths:["a","b"],readTags:{_ in await other.tag(.unavailable)},readInfo:{_ in await other.finder(true)}))
        #expect(await other.counts()==[1,1])
    }
    @Test func budgetStopsNewReadsAndCancellationDoesNotEnable() async throws {
        let counts=ProbeCounts()
        #expect(try await !SMBDirectoryProvider.probeFinderEvidence(paths:["a","b"],budget:0.01,readTags:{_ in
            try await Task.sleep(for:.milliseconds(30));return await counts.tag(.unavailable)
        },readInfo:{_ in await counts.finder(true)}))
        #expect(await counts.counts()==[1,0])
        let task=Task {
            try await SMBDirectoryProvider.probeFinderEvidence(paths:["a"],readTags:{_ in
                try? await Task.sleep(for:.milliseconds(100));return .loaded([FinderTag(name:"late",color:0)])
            },readInfo:{_ in true})
        }
        task.cancel()
        do {_ = try await task.value;Issue.record("Cancelled probe returned a result")}catch is CancellationError {}catch {Issue.record("Unexpected error")}
    }
}

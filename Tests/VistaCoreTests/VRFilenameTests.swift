import Testing
@testable import VistaCore
struct VRFilenameTests {
    @Test func dimensionsResolveIndependently() {
        let value=VRDimensionResolver.resolve(manual:.init(layout:.overUnder),metadata:.init(projection:.equirectangular360,swapEyes:true),filename:"sample_SBS_VR180.mp4")
        #expect(value.values == .init(projection:.equirectangular360,layout:.overUnder,swapEyes:true))
        #expect(value.layoutOrigin == .manual && value.projectionOrigin == .metadata)
        let partial=VRDimensionResolver.resolve(metadata:.init(layout:.mono),filename:"sample_SBS_VR180.mp4")
        #expect(partial.values.layout == .mono && partial.values.projection == .equirectangular180)
    }
    @Test func explicitTokensAndChinese() {
        for name in ["旅程_上下_VR360.mp4","film.OU.360.mp4","film-TB-360.mp4"] {
            let value=VRFilenameHints.parse(name)
            #expect(value.values.layout == .overUnder && value.values.projection == .equirectangular360)
        }
        #expect(VRFilenameHints.parse("film_[SBS]_[180°].mp4").values == .init(projection:.equirectangular180,layout:.sideBySide))
    }
    @Test func titleNumbersDoNotBecomeProjection() {
        for name in ["電影 180.mp4","360 天.mp4","movie180.mp4","film_1800.mp4","about.mp4","上下班日記.mp4"] {
            let value=VRDimensionResolver.resolve(filename:name)
            #expect(VRFilenameHints.parse(name).values.projection == nil)
            #expect(value.values.projection == .equirectangular180 && value.projectionOrigin == .fallback)
            #expect(value.values.layout == .sideBySide && value.layoutOrigin == .fallback)
        }
    }
    @Test func conflictingSignalsStayUnresolvedUnlessHigherPriorityWins() {
        let value=VRDimensionResolver.resolve(filename:"film_SBS_TB_VR180_VR360.mp4")
        #expect(value.values.layout == nil && value.values.projection == nil)
        let explicit=VRDimensionResolver.resolve(metadata:.init(projection:.equirectangular360,layout:.mono),filename:"SBS_OU_180_360.mp4")
        #expect(explicit.values.projection == .equirectangular360 && explicit.values.layout == .mono)
        #expect(VRFilenameHints.parse("film_fisheye.mp4").values.projection == nil)
    }
}

import Foundation
extension VRFilenameTests {
    @Test @MainActor func partialManualChoicesSurviveReloadAndDoNotMaskOtherDimensions() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let url=folder.appendingPathComponent("formats.json"),file=try MediaFile(components:["synthetic.mp4"])
        let store=try VRPreferenceStore(url:url)
        try store.saveDimensions(.init(layout:.overUnder),source:.demo,file:file,revision:"one")
        let loaded=try VRPreferenceStore(url:url).loadDimensions(source:.demo,file:file,revision:"one")
        #expect(loaded == .init(layout:.overUnder))
        #expect(VRDimensionResolver.resolve(manual:loaded!,metadata:.init(projection:.equirectangular360),filename:"SBS_180.mp4").values.projection == .equirectangular360)
        try store.save(VRFormat(VRSettings()),source:.demo,file:file,revision:"legacy")
        #expect(try VRPreferenceStore(url:url).loadDimensions(source:.demo,file:file,revision:"legacy") == VRFormatDimensions(VRFormat(VRSettings())))
    }
}

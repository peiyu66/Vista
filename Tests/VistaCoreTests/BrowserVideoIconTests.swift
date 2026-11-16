import Testing
@testable import VistaCore

@Suite struct BrowserVideoIconTests {
    @Test(arguments: ["short.mkv", "UPPER.MKV", "Mixed.MkV", "影片.test.mkv"])
    func mkvUsesFilledFilm(_ name: String) {
        #expect(FileEntry(name, .video).browserSymbolName == "film.fill")
    }
    @Test(arguments: ["short.mp4", "UPPER.MP4", "short.mov", "short.m4v", "name.mkv.mp4", "name.mkv.bak", "no-extension"])
    func otherVideosKeepFilm(_ name: String) {
        #expect(FileEntry(name, .video).browserSymbolName == "film")
    }
    @Test func kindRemainsAuthoritative() {
        #expect(FileEntry("folder.mkv", .directory).browserSymbolName == "folder.fill")
        #expect(FileEntry("document.mkv", .other).browserSymbolName == "doc")
    }
}

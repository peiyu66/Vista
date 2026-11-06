import Testing
@testable import VistaCore
struct OrderedVideoNavigationTests {
    @Test func followsDisplayedOrderAndSkipsNonVideos() {
        let entries=[FileEntry("folder",.directory),FileEntry("z.mp4",.video),FileEntry("notes",.other),FileEntry("a.mp4",.video)]
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"z.mp4",backward:false)?.name == "a.mp4")
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"a.mp4",backward:true)?.name == "z.mp4")
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"z.mp4",backward:true) == nil)
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"a.mp4",backward:false) == nil)
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"deleted.mp4",backward:false) == nil)
        #expect(OrderedVideoNavigation.adjacent(in:[],currentID:"z.mp4",backward:true) == nil)
    }
    @Test func largeReverseOrderPreservesEdges() {
        let entries=(0..<5000).reversed().map{FileEntry("clip-\($0).mp4",.video)}
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"clip-2500.mp4",backward:true)?.name == "clip-2501.mp4")
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"clip-2500.mp4",backward:false)?.name == "clip-2499.mp4")
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"clip-4999.mp4",backward:true) == nil)
        #expect(OrderedVideoNavigation.adjacent(in:entries,currentID:"clip-0.mp4",backward:false) == nil)
    }
}

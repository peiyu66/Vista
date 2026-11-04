import Foundation
import Testing
@testable import VistaCore
struct BubbleFlowTests {
    @Test func wrapsAndPreservesHorizontalRows() {
        let sizes=[CGSize(width:90,height:30),CGSize(width:80,height:40),CGSize(width:100,height:32)]
        let flow=BubbleFlow.positions(sizes:sizes,width:200)
        #expect(flow.points == [CGPoint(x:0,y:0),CGPoint(x:98,y:0),CGPoint(x:0,y:48)])
        #expect(flow.height==80)
        let narrow=BubbleFlow.positions(sizes:sizes,width:100)
        #expect(narrow.points.map(\.y)==[0,38,86])
        #expect(narrow.height==118)
    }
    @Test func emptyAndOversizeStayWithinContainer() {
        #expect(BubbleFlow.positions(sizes:[],width:320).height==0)
        let flow=BubbleFlow.positions(sizes:[CGSize(width:900,height:40),CGSize(width:50,height:20)],width:240)
        #expect(flow.points==[CGPoint(x:0,y:0),CGPoint(x:0,y:48)])
    }
}

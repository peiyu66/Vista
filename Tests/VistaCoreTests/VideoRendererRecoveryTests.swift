import Foundation
import Testing
@testable import VistaCore

struct VideoRendererRecoveryTests {
    @Test func noSessionCannotRecover() {
        var gate=VideoRendererRecoveryGate()
        #expect(gate.requestRecovery() == .failed)
    }
    @Test func oneRecoveryPerForegroundInterval() {
        var gate=VideoRendererRecoveryGate();let session=UUID()
        gate.selectSession(session)
        #expect(gate.requestRecovery() == .retry)
        gate.selectSession(session) // Ordinary frames and format changes cannot reset budget.
        #expect(gate.requestRecovery() == .failed)
        let duplicateActive=gate.setSceneActive(true);#expect(!duplicateActive)
        #expect(gate.requestRecovery() == .failed)
    }
    @Test func suspendedDoesNotConsumeRecoveryOrResumePlayback() {
        var gate=VideoRendererRecoveryGate();gate.selectSession(UUID())
        let suspended=gate.setSceneActive(false);#expect(suspended)
        #expect(gate.requestRecovery() == .deferred)
        #expect(!gate.attempted && !gate.sceneActive)
        let duplicateInactive=gate.setSceneActive(false);#expect(!duplicateInactive)
        #expect(gate.requestRecovery() == .deferred)
        let activated=gate.setSceneActive(true);#expect(activated)
        #expect(gate.requestRecovery() == .retry)
        #expect(gate.requestRecovery() == .failed)
    }
    @Test func repeatedRealInterruptionsGetBoundedIndependentAttempts() {
        var gate=VideoRendererRecoveryGate();gate.selectSession(UUID())
        for _ in 0..<20 {
            gate.setSceneActive(false)
            #expect(gate.requestRecovery() == .deferred)
            gate.setSceneActive(true)
            #expect(gate.requestRecovery() == .retry)
            #expect(gate.requestRecovery() == .failed)
        }
    }
    @Test func newVideoGetsFreshBudgetButStaysSuspended() {
        var gate=VideoRendererRecoveryGate();gate.selectSession(UUID())
        #expect(gate.requestRecovery() == .retry)
        gate.setSceneActive(false);gate.selectSession(UUID())
        #expect(!gate.sceneActive && gate.requestRecovery() == .deferred)
        gate.setSceneActive(true)
        #expect(gate.requestRecovery() == .retry)
    }
    @Test func stopInvalidatesSessionWithoutChangingSceneState() {
        var gate=VideoRendererRecoveryGate();gate.selectSession(UUID())
        gate.setSceneActive(false);gate.stop()
        #expect(gate.session == nil && !gate.sceneActive)
        #expect(gate.requestRecovery() == .failed)
        gate.selectSession(UUID())
        #expect(gate.requestRecovery() == .deferred)
    }
}

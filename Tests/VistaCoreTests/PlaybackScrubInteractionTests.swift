import Foundation
import Testing
@testable import VistaCore

struct PlaybackScrubInteractionTests {
    @Test func unchangedEditingRoundTripDoesNotSubmit() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.begin(owner: owner, position: 1335.51715)
        #expect(edit.finish(owner: owner) == nil)
        #expect(!edit.isActive && !edit.changed)
    }
    @Test func exactSameSetterDoesNotSubmit() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(42, owner: owner, initialPosition: 42)
        #expect(edit.finish(owner: owner) == nil)
    }
    @Test(arguments: [true, false]) func setterAndBeginOrderPreservesChangedTarget(setterFirst: Bool) {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        if !setterFirst { edit.begin(owner: owner, position: 42) }
        edit.update(43, owner: owner, initialPosition: 42)
        if setterFirst { edit.begin(owner: owner, position: 42.5) }
        #expect(edit.finish(owner: owner) == 43)
        #expect(!edit.isActive)
    }
    @Test func realEditReturningToStartStillSubmits() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.begin(owner: owner, position: 42)
        edit.update(43, owner: owner, initialPosition: 42)
        edit.update(42, owner: owner, initialPosition: 42.5)
        #expect(edit.finish(owner: owner) == 42)
    }
    @Test func smallestRepresentableChangeStillSubmits() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(42.0.nextUp, owner: owner, initialPosition: 42)
        #expect(edit.finish(owner: owner) == 42.0.nextUp)
    }
    @Test func movingPlaybackClockAloneDoesNotCreateAnEdit() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.begin(owner: owner, position: 42)
        edit.begin(owner: owner, position: 45)
        #expect(edit.finish(owner: owner) == nil)
    }
    @Test(arguments: [0.0, 100.0]) func endpointsAreRealChanges(target: Double) {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(target, owner: owner, initialPosition: 42)
        #expect(edit.finish(owner: owner) == target)
    }
    @Test func cancelledEditAndDuplicateEndNeverSubmit() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(43, owner: owner, initialPosition: 42)
        edit.cancel()
        #expect(edit.finish(owner: owner) == nil)
        edit.update(44, owner: owner, initialPosition: 42)
        #expect(edit.finish(owner: owner) == 44)
        #expect(edit.finish(owner: owner) == nil)
    }
    @Test func replacementRetiresOldEditWithoutSuppressingNewOne() {
        let old = UUID(), new = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(43, owner: old, initialPosition: 42)
        edit.retainOnly(owner: new)
        #expect(!edit.isActive && edit.finish(owner: old) == nil)
        edit.update(2, owner: new, initialPosition: 1)
        #expect(edit.finish(owner: old) == nil && edit.isActive)
        edit.retainOnly(owner: new)
        #expect(edit.finish(owner: new) == 2)
    }
    @Test func disappearanceClearsOwnerAndInvalidValuesCannotCommit() {
        let owner = UUID(); var edit = PlaybackScrubInteraction()
        edit.update(43, owner: owner, initialPosition: 42)
        edit.retainOnly(owner: nil)
        edit.update(.nan, owner: owner, initialPosition: 42)
        edit.begin(owner: owner, position: .infinity)
        #expect(!edit.isActive && edit.finish(owner: owner) == nil)
    }
}

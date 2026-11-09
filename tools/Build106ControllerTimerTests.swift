// App controller methods and the selected-rate callback are inserted by the runner.
// The player and pose types are local substitutes; no media or UI is launched.
import Foundation
import Observation

struct VRSettings {}
final class VRViewCalibration { func videoSettings(for settings: VRSettings) -> VRSettings { settings } }
struct PlaybackSpeedStatus { var selected: Double = 1; var effectiveRate: Double = 1; var waiting = false }
@MainActor @Observable final class PlaybackController {
    var isPlaying = true
    var isPaused = false
    var isPreparing = false
    var speedStatus = PlaybackSpeedStatus()
    func stop() { isPlaying = false }
}

// PRODUCTION_CONTROLLER
// PRODUCTION_RATE_OBSERVER

@main struct TimerTests {
    @MainActor static func main() async throws {
        var results: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            results.append(["name": name, "passed": passed])
            print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func make(_ rate: Double = 1) -> VRPresentation {
            let p = VRPresentation(); p.active = true; p.player = PlaybackController()
            p.player!.speedStatus.selected = rate; return p
        }
        func rate(_ p: VRPresentation, _ selected: Double) {
            p.player!.speedStatus.selected = selected; selectedRateDidChange(p)
        }
        let normal = make(); normal.scheduleHide()
        let accelerated = [1.5, 2.0, 5.0].map { value in let p = make(value); p.scheduleHide(); return p }
        let zeroEffective = make(2); zeroEffective.player!.speedStatus.effectiveRate = 0
        zeroEffective.player!.speedStatus.waiting = true; zeroEffective.scheduleHide()
        let waitingAtOne = make(); waitingAtOne.player!.speedStatus.waiting = true; waitingAtOne.scheduleHide()
        let paused = make(); paused.player!.isPaused = true; paused.scheduleHide()
        let preparing = make(); preparing.player!.isPreparing = true; preparing.scheduleHide()
        let settings = make(); settings.settingsVisible = true; settings.scheduleHide()
        let diagnostics = make(); diagnostics.diagnosticsVisible = true; diagnostics.scheduleHide()
        let scrubbing = make(); scrubbing.scrubbing = true; scrubbing.scheduleHide()
        let moving = make(); moving.movingControls = true; moving.scheduleHide()
        let message = make(); message.message = "test"; message.scheduleHide()
        let format = make(); format.requiresFormatConfirmation = true; format.scheduleHide()
        let advancing = make(); advancing.advancing = true; advancing.scheduleHide()
        let inactive = make(); inactive.active = false; inactive.scheduleHide()
        let testPattern = make(); testPattern.testPattern = true; testPattern.scheduleHide()
        let noPlayer = make(); noPlayer.player = nil; noPlayer.scheduleHide()
        let stopped = make(); stopped.player!.isPlaying = false; stopped.scheduleHide()
        // Leave the old timer alive deliberately, to exercise the deadline guard independently.
        let staleRate = make(); staleRate.scheduleHide()
        let staleNavigation = make(); staleNavigation.scheduleHide()
        let cancellation = make(); cancellation.scheduleHide()
        let reset = make(); reset.scheduleHide()
        let resume = make(); resume.scheduleHide()
        let hidden = make(5); hidden.scheduleHide(); hidden.toggleControlsFromBackground()
        let navigationShown = make(2); navigationShown.beginControllerNavigation()
        let navigationHidden = make(2); navigationHidden.toggleControlsFromBackground(); navigationHidden.beginControllerNavigation()
        let showAgain = make(2); showAgain.toggleControlsFromBackground(); showAgain.toggleControlsFromBackground()
        let navigationToggle = make(2); navigationToggle.beginControllerNavigation(); navigationToggle.toggleControlsFromBackground()
        let failedNavigation = make(2); failedNavigation.toggleControlsFromBackground(); failedNavigation.beginControllerNavigation()
        let finish = make(); finish.scheduleHide(); finish.finishSession()
        try await Task.sleep(for: .seconds(1.5))
        check("normal_timer_does_not_hide_before_three_seconds", normal.controlsVisible)
        staleRate.player!.speedStatus.selected = 2
        staleNavigation.navigationVisibility = true
        rate(cancellation, 2)
        rate(reset, 2)
        // Preserve the real button ordering: reveal at the old high rate, then reset, then observer.
        reset.revealControls(); rate(reset, 1)
        resume.player!.isPaused = true; resume.revealControls()
        resume.player!.isPaused = false; resume.revealControls()
        for selected in [4.5, 4.0, 3.5, 3.0, 2.5, 2.0] {
            rate(hidden, selected)
            check("manual_hidden_remains_hidden_after_auto_rate_\(selected)", !hidden.controlsVisible)
        }
        // Incoming file starts at 1x while navigation visibility is still being preserved.
        rate(navigationShown, 1); rate(navigationHidden, 1)
        navigationShown.revealControls(); navigationHidden.revealControls()
        navigationShown.holdControls(); navigationHidden.holdControls()
        check("navigation_reveal_and_hold_preserve_hidden", !navigationHidden.controlsVisible)
        try await Task.sleep(for: .seconds(1.8))
        check("normal_one_x_hides_after_three_seconds", !normal.controlsVisible)
        for (index, p) in accelerated.enumerated() { check("selected_\([1.5, 2.0, 5.0][index])_stays_visible", p.controlsVisible) }
        check("selected_two_x_with_zero_effective_and_waiting_stays_visible", zeroEffective.controlsVisible)
        check("waiting_alone_at_one_x_does_not_gain_persistence", !waitingAtOne.controlsVisible)
        for (name, p) in [("paused", paused), ("preparing", preparing), ("settings", settings), ("diagnostics", diagnostics), ("scrubbing", scrubbing), ("moving", moving), ("message", message), ("format", format), ("advancing", advancing), ("inactive", inactive), ("test_pattern", testPattern), ("missing_player", noPlayer), ("stopped", stopped)] {
            check("existing_\(name)_gate_stays_visible", p.controlsVisible)
        }
        check("deadline_rechecks_selected_even_without_observer", staleRate.controlsVisible)
        check("deadline_rechecks_navigation_even_without_cancel", staleNavigation.controlsVisible)
        check("one_to_two_cancels_old_timer", cancellation.controlsVisible)
        check("reset_to_one_has_not_used_old_deadline", reset.controlsVisible)
        check("resume_has_not_used_old_deadline", resume.controlsVisible)
        check("multiple_auto_reductions_never_reveal", !hidden.controlsVisible)
        check("navigation_shown_has_no_timer_after_selected_reset", navigationShown.controlsVisible)
        check("navigation_hidden_has_no_timer_or_reveal_after_selected_reset", !navigationHidden.controlsVisible)
        check("manual_show_at_two_x_stays_visible", showAgain.controlsVisible)
        check("navigation_manual_toggle_updates_saved_visibility", navigationToggle.navigationVisibility == false && !navigationToggle.controlsVisible)
        check("finish_cancels_pending_timer_and_clears_player", finish.controlsVisible && finish.player == nil && !finish.active)
        navigationShown.endControllerNavigation(); navigationHidden.endControllerNavigation()
        navigationToggle.endControllerNavigation()
        failedNavigation.endControllerNavigation(showError: true)
        check("navigation_end_preserves_manual_hidden", !navigationHidden.controlsVisible && !navigationToggle.controlsVisible)
        check("navigation_error_still_reveals", failedNavigation.controlsVisible)
        rate(hidden, 1)
        check("reset_hidden_to_one_does_not_reveal", !hidden.controlsVisible)
        try await Task.sleep(for: .seconds(1.6))
        check("reset_to_one_hides_after_fresh_three_seconds", !reset.controlsVisible)
        check("resume_hides_after_fresh_three_seconds", !resume.controlsVisible)
        check("navigation_end_starts_fresh_three_seconds", navigationShown.controlsVisible)
        check("old_cancelled_task_never_hides_accelerated_controls", cancellation.controlsVisible)
        try await Task.sleep(for: .seconds(1.8))
        check("navigation_end_one_x_hides_after_fresh_deadline", !navigationShown.controlsVisible)
        check("hidden_one_x_remains_hidden_after_deadline", !hidden.controlsVisible)
        let failed = results.filter { !($0["passed"] as! Bool) }.count
        let data = try JSONSerialization.data(withJSONObject: ["type": "real-production-controller-task-timers-with-player-substitute", "checks": results, "passed": results.count - failed, "total": results.count, "uiRuntimeExecuted": false], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if failed > 0 { exit(1) }
    }
}

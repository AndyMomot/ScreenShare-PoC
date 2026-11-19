import ActivityKit
import Foundation
import Shared
import UIKit

/// Mirrors the session into a Live Activity, so the driver sees it in the Dynamic Island and on the
/// Lock Screen and can end it from there. Started when sharing begins (the app is in front then).
final class LiveActivityController {
    private var activity: Activity<SupportSessionAttributes>?

    /// iOS keeps a Live Activity on screen for hours after the app is killed, while the session and the
    /// capture died with the process. A fresh launch has no session yet, so anything still shown is stale.
    init() {
        endAll(reason: "left over from a previous run")
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Not called for every kill (a suspended app gets no notice); the launch clean-up covers the rest.
            self?.endAllNow()
        }
    }

    /// Ends every activity of this app, including ones started by a previous run.
    func endAll(reason: String) {
        activity = nil
        let stale = Activity<SupportSessionAttributes>.activities
        guard !stale.isEmpty else { return }
        DiagLog.shared.log("activity", "ending \(stale.count) activity(ies): \(reason)")
        Task {
            for item in stale { await item.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The process is about to exit: wait for the end to be delivered instead of starting a task.
    private func endAllNow() {
        let all = Activity<SupportSessionAttributes>.activities
        guard !all.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for item in all { await item.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    func update(for state: SessionState) {
        guard let streaming = state as? SessionStateStreaming else {
            end()
            return
        }
        let phase: SupportSessionAttributes.Phase =
            streaming.paused ? .paused : (streaming.controlEnabled ? .control : .viewing)
        let content = ActivityContent(state: SupportSessionAttributes.ContentState(phase: phase), staleDate: nil)

        if let activity {
            Task { await activity.update(content) }
            DiagLog.shared.log("activity", "updated → \(phase.rawValue)")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            DiagLog.shared.log("activity", "Live Activities are turned off for this app in Settings")
            return
        }
        let attributes = SupportSessionAttributes(
            supportName: "Support",
            wholeDevice: streaming.mode == CaptureMode.device,
            startedAt: Date()
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            DiagLog.shared.log("activity", "started (\(phase.rawValue))")
        } catch {
            DiagLog.shared.log("activity", "could not start: \(error.localizedDescription)")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        DiagLog.shared.log("activity", "ended")
    }
}

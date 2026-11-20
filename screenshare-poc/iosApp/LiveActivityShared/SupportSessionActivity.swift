import ActivityKit
import AppIntents
import Foundation

/// What the Live Activity shows: compiled into the app and into the widget extension.
struct SupportSessionAttributes: ActivityAttributes {
    /// What support can currently do: only watch, watch and control, or nothing (sharing paused by iOS).
    enum Phase: String, Codable, Hashable {
        case viewing, control, paused
    }

    /// The part that changes during the session and is pushed with `Activity.update`.
    struct ContentState: Codable, Hashable {
        var phase: Phase
    }

    /// Fixed for the activity's lifetime: who is watching, app vs whole-device capture, start time for the timer.
    var supportName: String
    var wholeDevice: Bool
    var startedAt: Date
}

/// The "End" button in the Dynamic Island and on the Lock Screen. A Live Activity intent runs in the
/// app's process, so the app ends the session itself; the extension only shows the button.
struct EndSupportSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End support session"

    init() {}

    func perform() async throws -> some IntentResult {
        #if MAIN_APP
        await MainActor.run {
            NotificationCenter.default.post(name: .endSupportSessionFromActivity, object: nil)
        }
        #endif
        return .result()
    }
}

/// Posted in the app process when the driver taps End in the Live Activity; `SessionViewModel` observes it.
extension Notification.Name {
    static let endSupportSessionFromActivity = Notification.Name("endSupportSessionFromActivity")
}

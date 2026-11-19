import ActivityKit
import AppIntents
import Foundation

/// What the Live Activity shows: compiled into the app and into the widget extension.
struct SupportSessionAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case viewing, control, paused
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
    }

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

extension Notification.Name {
    static let endSupportSessionFromActivity = Notification.Name("endSupportSessionFromActivity")
}

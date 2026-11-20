import UserNotifications

/// Tells the driver, while the app is not in front, that iOS stopped the screen sharing
/// (lock, call) and that opening the app continues it.
enum Notifier {
    /// Fixed identifier: a new pause replaces the previous notification and `clear()` can remove it.
    private static let id = "sharing-paused"

    /// Asks once for alert/sound permission; the result is only logged.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DiagLog.shared.log("notify", "permission \(granted ? "granted" : "denied")\(error.map { " (\($0.localizedDescription))" } ?? "")")
        }
    }

    /// Posts the pause notification immediately (`trigger: nil`).
    static func sharingPaused() {
        let content = UNMutableNotificationContent()
        content.title = "Support can't see your screen"
        content.body = "iOS paused screen sharing. Open the app and confirm sharing to continue."
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            DiagLog.shared.log("notify", "sharing paused notification \(error.map { "failed: \($0.localizedDescription)" } ?? "shown")")
        }
    }

    /// Removes the pause notification once sharing runs again.
    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

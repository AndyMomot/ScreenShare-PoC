import SwiftUI

/// App entry point. The single `SessionViewModel` lives here for the whole process and is handed to all views.
@main
struct ScreenSharePoCApp: App {
    @StateObject private var session = SessionViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}

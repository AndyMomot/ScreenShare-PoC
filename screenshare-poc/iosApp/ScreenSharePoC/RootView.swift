import Shared
import SwiftUI

/// Top-level screen: three tabs, the session banner above them, and the two consent prompts
/// (viewing request as a sheet, control request as an alert) driven by the session state.
struct RootView: View {
    @EnvironmentObject private var session: SessionViewModel

    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Session", systemImage: "dot.radiowaves.left.and.right") }
            DemoScreensView()
                .tabItem { Label("Screens", systemImage: "square.grid.2x2") }
            ClockView()
                .tabItem { Label("Clock", systemImage: "clock") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SessionBanner()
        }
        .sheet(isPresented: requestPresented) {
            RequestView()
                .interactiveDismissDisabled()
        }
        .alert("Support asks to control the app", isPresented: controlRequestPresented) {
            Button("Allow") { session.grantControl() }
            Button("Deny", role: .cancel) { session.denyControl() }
        } message: {
            Text("Support will be able to tap, scroll and type inside this app. You can turn it off at any time.")
        }
    }

    /// Sheet is shown purely from state; the setter is a no-op because only Accept/Decline (or timeout) close it.
    private var requestPresented: Binding<Bool> {
        Binding(get: { session.requested != nil }, set: { _ in })
    }

    /// If the alert goes away without an answer while the request is still pending, treat it as Deny.
    private var controlRequestPresented: Binding<Bool> {
        Binding(
            get: { session.streaming?.controlRequested == true },
            set: { shown in if !shown, session.streaming?.controlRequested == true { session.denyControl() } }
        )
    }
}

/// Persistent indicator shown on every tab while a session is active.
struct SessionBanner: View {
    @EnvironmentObject private var session: SessionViewModel

    var body: some View {
        if let streaming = session.streaming {
            HStack(spacing: 12) {
                Circle().fill(streaming.paused ? Color.orange : Color.red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(streaming.paused ? "Session paused" : "Support is viewing").font(.subheadline.bold())
                    Text(streaming.controlEnabled ? "Control: ON" : "Control: off").font(.caption)
                }
                Spacer()
                if streaming.controlEnabled {
                    Button("Control off") { session.revokeControl() }
                        .buttonStyle(.bordered)
                }
                Button("End", role: .destructive) { session.end() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
}

/// Viewing consent with the capture mode and a live countdown to the request deadline.
struct RequestView: View {
    @EnvironmentObject private var session: SessionViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.wave.2.fill").font(.system(size: 56))
            if let request = session.requested {
                Text("\(request.supportName) wants to view your screen")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(request.mode == CaptureMode.device ? "Mode: whole device" : "Mode: this app only")
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // deadlineMillis is epoch milliseconds from the shared controller.
                    let left = max(0, Int(Double(request.deadlineMillis) / 1000 - context.date.timeIntervalSince1970))
                    Text("Request expires in \(left) s").monospacedDigit()
                }
            }
            HStack(spacing: 16) {
                Button("Decline", role: .destructive) { session.decline() }
                    .buttonStyle(.bordered)
                Button("Accept") { session.accept() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}

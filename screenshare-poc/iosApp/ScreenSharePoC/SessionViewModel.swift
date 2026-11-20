import Foundation
import LiveKit
import Shared
import UIKit

/// Link to the media server, as the driver sees it.
enum LinkStatus: Equatable {
    case searching
    case connecting
    case online
    case reconnecting
    case offline(retryIn: Int, reason: String?)
}

/// Bridges the shared SessionController to SwiftUI, owns the LiveKit engine
/// and keeps the app in the room on its own: on launch, on return from background, after a drop.
final class SessionViewModel: ObservableObject {
    /// Optional override; empty means "find the server on the network".
    @Published var manualHost: String {
        didSet { UserDefaults.standard.set(manualHost, forKey: "manualHost") }
    }
    /// Server currently announced over Bonjour, if any.
    @Published private(set) var discovered: ServerDiscovery.Server?
    /// Persisted control mode; a change is announced to the support page right away.
    @Published var controlMode: ControlMode = ControlMode.current {
        didSet {
            ControlMode.current = controlMode
            announceControlMode()
        }
    }
    /// Persisted choice of capture framework for app mode; used from the next capture on.
    @Published var captureAPI: CaptureAPI = CaptureAPI.current {
        didSet {
            CaptureAPI.current = captureAPI
            DiagLog.shared.log("driver", "capture API → \(captureAPI.rawValue)")
        }
    }
    /// Encoding profile handed to the engine for the next capture.
    @Published var profile: StreamProfile = .smooth {
        didSet {
            engine.profile = profile
            DiagLog.shared.log("driver", "profile → \(profile.title)")
        }
    }
    @Published private(set) var link: LinkStatus = .searching
    /// Mirror of the controller's state, updated through `watchState` so SwiftUI can observe it.
    @Published private(set) var state: SessionState = SessionStateIdle.shared
    /// Newest-first on-screen log, last 200 lines.
    @Published private(set) var log: [String] = []

    let engine: LiveKitEngine
    let controller: SessionController
    /// Keeps the state subscription alive; cancelled in deinit.
    private var watch: Cancellable?
    private var observers: [NSObjectProtocol] = []
    private var retryWork: DispatchWorkItem?
    private var retryDelays = RetryDelays()
    /// Guards against overlapping joins from discovery, retries and foreground events.
    private var isJoining = false
    private let discovery = ServerDiscovery()
    /// Host of the last join attempt, to tell a genuinely new Bonjour announcement from a repeat.
    private var joinedHost: String?
    private let liveActivity = LiveActivityController()
    /// Who asked for the current session; the Live Activity shows it.
    private var supportName = "Support"
    /// iOS ended the capture (lock, call); it is started again, with a new consent, on return.
    private var resumeCaptureOnReturn = false

    /// The server the app talks to: the typed address if any, otherwise the one found by Bonjour.
    var host: String? {
        let typed = manualHost.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? discovered?.host : typed
    }

    /// Wires engine callbacks into the controller, starts discovery and makes the first join attempt.
    init() {
        DiagLog.shared.start()
        manualHost = UserDefaults.standard.string(forKey: "manualHost") ?? ""
        let engine = LiveKitEngine()
        self.engine = engine
        controller = SessionController(engine: engine)

        engine.onMessage = { [weak self] text in
            self?.append("← \(text)")
            self?.controller.onRemoteMessage(text: text)
        }
        engine.onConnectionState = { [weak self] state in self?.connectionChanged(state) }
        engine.onLog = { [weak self] line in self?.append(line) }
        engine.onCaptureInterrupted = { [weak self] in self?.captureInterrupted() }
        // A successful start after an interruption ends the pause; the first start of a session needs nothing here.
        engine.onCaptureStarted = { [weak self] in
            guard let self, self.streaming?.paused == true else { return }
            self.append("capture back → resume")
            self.controller.setPaused(paused: false)
        }
        engine.onCaptureFailed = { [weak self] reason in
            guard let self, self.streaming != nil else { return }
            self.append("capture could not start (\(reason)) → ending the session")
            self.controller.endByDriver()
        }
        watch = controller.watchState { [weak self] state in self?.sessionChanged(state) }
        observeLifecycle()
        observers.append(NotificationCenter.default.addObserver(
            forName: .endSupportSessionFromActivity, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.streaming != nil else {
                // A card with no session behind it (e.g. after the app was killed): just remove it.
                self.liveActivity.endAll(reason: "End pressed with no session running")
                return
            }
            self.append("driver ended the session from the Live Activity")
            self.controller.endByDriver()
        })
        discovery.onChange = { [weak self] server in self?.discoveredChanged(server) }
        discovery.start()
        DispatchQueue.main.async { [weak self] in self?.join() }
    }

    deinit {
        watch?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Convenience casts of the Kotlin sealed state for SwiftUI.
    var streaming: SessionStateStreaming? { state as? SessionStateStreaming }
    var requested: SessionStateRequested? { state as? SessionStateRequested }

    private func discoveredChanged(_ server: ServerDiscovery.Server?) {
        guard server != discovered else { return }
        discovered = server
        append(server.map { "found \($0.name) at \($0.host)" } ?? "server announcement gone")
        guard manualHost.trimmingCharacters(in: .whitespaces).isEmpty, let server, server.host != joinedHost else { return }
        // A different Mac (or the same Mac on a new network) is now announcing: follow it.
        reconnect()
    }

    /// Called after the server address changes: leave the old server and join the new one.
    func reconnect() {
        retryWork?.cancel()
        retryDelays.reset()
        Task { @MainActor in
            await engine.disconnect()
            join()
        }
    }

    /// Notification permission is asked at Accept, when the driver understands why a pause notice could matter.
    func accept() {
        tapped("Accept")
        Notifier.requestPermission()
        controller.accept()
    }
    func decline() { tapped("Decline"); controller.decline() }
    func end() { tapped("End"); controller.endByDriver() }
    func grantControl() { tapped("Allow control"); controller.grantControl() }
    func denyControl() { tapped("Deny control"); controller.denyControl() }
    func revokeControl() { tapped("Control off"); controller.revokeControl() }

    /// Logs a driver button press with the state it was pressed in.
    private func tapped(_ button: String) {
        DiagLog.shared.log("driver", "pressed \(button) · state \(state)")
    }

    /// Adds a line to the on-screen log and DiagLog; hops to main because engine callbacks may come from elsewhere.
    func append(_ line: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.append(line) }
            return
        }
        let time = Date().formatted(.dateTime.hour().minute().second())
        log.insert("\(time) \(line)", at: 0)
        DiagLog.shared.log("app", line)
        if log.count > 200 { log.removeLast() }
    }

    // MARK: - Joining the room

    /// Fetches a token and connects to LiveKit on the chosen host. Does nothing while a join is running
    /// or the room is not disconnected; with no host yet it waits for discovery.
    private func join() {
        guard !isJoining, engine.connectionState == .disconnected else { return }
        guard let host else {
            link = .searching
            return
        }
        DiagLog.shared.host = host
        isJoining = true
        retryWork?.cancel()
        link = .connecting
        Task { @MainActor in
            defer { isJoining = false }
            do {
                let token = try await fetchToken(host: host)
                joinedHost = host
                try await engine.connect(url: "ws://\(host):7880", token: token)
            } catch {
                append("join failed: \(error.localizedDescription)")
                scheduleRetry(reason: error.localizedDescription)
            }
        }
    }

    /// Maps LiveKit connection states to the link status; an unexpected disconnect schedules a rejoin.
    private func connectionChanged(_ state: ConnectionState) {
        switch state {
        case .connected:
            retryDelays.reset()
            link = .online
        case .connecting:
            link = .connecting
        case .reconnecting:
            link = .reconnecting
        case .disconnected:
            // A failed join schedules its own retry; avoid scheduling a second one here.
            if !isJoining { scheduleRetry(reason: nil) }
        case .disconnecting:
            break
        @unknown default:
            break
        }
    }

    /// Rejoins after the next backoff delay; any earlier pending retry is replaced.
    private func scheduleRetry(reason: String?) {
        guard host != nil else {
            link = .searching
            return
        }
        let delay = retryDelays.next()
        link = .offline(retryIn: delay, reason: reason)
        let work = DispatchWorkItem { [weak self] in self?.join() }
        retryWork?.cancel()
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }

    /// One identity per installation: two apps joining as the same participant (a phone and a
    /// simulator, say) would keep disconnecting each other. The support page accepts any "driver-…".
    private static let identity: String = {
        let id = UIDevice.current.identifierForVendor?.uuidString.prefix(5).lowercased() ?? "x"
        #if targetEnvironment(simulator)
        return "driver-sim-\(id)"
        #else
        return "driver-\(id)"
        #endif
    }()

    /// The token server answers with the bare JWT as the response body.
    private func fetchToken(host: String) async throws -> String {
        guard let url = URL(string: "http://\(host):8080/token?identity=\(Self.identity)&name=Driver&room=demo") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Session and lifecycle

    /// An ended session clears itself so the next request can arrive without any taps.
    private func sessionChanged(_ newState: SessionState) {
        DiagLog.shared.log("session", "\(state) → \(newState)")
        let wasStreaming = state is SessionStateStreaming
        state = newState
        if let requested = newState as? SessionStateRequested { supportName = requested.supportName }
        liveActivity.update(for: newState, supportName: supportName)
        if newState is SessionStateStreaming, !wasStreaming { announceControlMode() }
        if newState is SessionStateEnded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.controller.reset() }
        }
    }

    /// Tells the support page which control this build offers; the page shows it next to the controls.
    private func announceControlMode() {
        guard streaming != nil else { return }
        engine.sendMessage(json: #"{"type":"control_mode","mode":"\#(controlMode.rawValue)"}"#, reliable: true)
    }

    /// iOS stopped the capture: decide whether the driver stopped it deliberately (end) or iOS did (pause and resume later).
    private func captureInterrupted() {
        guard streaming != nil else { return }
        // Locking the phone also stops the stream while the app is still in front, so look again a
        // moment later: still in front and unlocked means the driver pressed Stop in the system UI.
        let callAtStop = CallMonitor.shared.hasCall
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.streaming != nil else { return }
            let app = UIApplication.shared
            let inCall = callAtStop || CallMonitor.shared.hasCall
            if app.applicationState == .active, app.isProtectedDataAvailable, !inCall {
                self.append("screen capture stopped from the system UI → ending the session")
                self.controller.endByDriver()
                return
            }
            self.append("iOS stopped the screen capture (\(inCall ? "phone call" : "lock / background")) → paused until the driver is back in the app")
            self.resumeCaptureOnReturn = true
            self.controller.setPaused(paused: true)
            // Only when the driver is really away; on a quick unlock the app is already coming back.
            if app.applicationState == .background { Notifier.sharingPaused() }
        }
    }

    /// Restarts capture after a pause caused by iOS, once the app is active and no call is in progress.
    private func resumeCapture() {
        guard resumeCaptureOnReturn, streaming != nil else { return }
        // The system picker cannot show over a call; wait for it to end.
        guard !CallMonitor.shared.hasCall, UIApplication.shared.applicationState == .active else { return }
        resumeCaptureOnReturn = false
        Notifier.clear()
        append("asking the driver to share the screen again")
        engine.restartCapture()
    }

    /// In-app capture stops in the background; device capture keeps running.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let streaming = self.streaming, streaming.mode == CaptureMode.app else { return }
            self.append("app → background")
            self.controller.setPaused(paused: true)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.streaming?.paused == true, !self.resumeCaptureOnReturn {
                self.append("app → foreground")
                self.controller.setPaused(paused: false)
            }
            self.retryDelays.reset()
            self.join()
        })
        // A call answered or declined from a banner never takes the app out of the foreground.
        CallMonitor.shared.onAllCallsEnded = { [weak self] in self?.resumeCapture() }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // The system picker can be shown only while the app is active.
            self?.resumeCapture()
        })
    }
}

/// 1, 2, 4, 8, then every 10 seconds.
private struct RetryDelays {
    private var attempt = 0

    mutating func next() -> Int {
        // The counter stops at 4 (16 s, capped to 10): an unbounded shift would overflow after
        // ~63 failures and turn the delay into 0, retrying in a tight loop.
        defer { attempt = min(attempt + 1, 4) }
        return min(1 << attempt, 10)
    }

    mutating func reset() { attempt = 0 }
}

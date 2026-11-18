import CallKit

/// Knows whether a phone call is ringing or in progress. An incoming call shown as a banner stops
/// whole-device capture while the app stays in front, which otherwise looks like the driver pressing Stop.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = CallMonitor()

    private let observer = CXCallObserver()
    /// Called on the main thread when the last call ends.
    var onAllCallsEnded: (() -> Void)?

    private override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var hasCall: Bool { observer.calls.contains { !$0.hasEnded } }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        DiagLog.shared.log("system", "call \(call.isOutgoing ? "outgoing" : "incoming") · connected \(call.hasConnected) · ended \(call.hasEnded) · on hold \(call.isOnHold)")
        if call.hasEnded, !hasCall { onAllCallsEnded?() }
    }
}

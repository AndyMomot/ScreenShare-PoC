import CoreMedia
import CoreVideo
import LiveKit
import ReplayKit
import UIKit
import VideoToolbox

/// Screen capture with our own frame path: ReplayKit (this app) or ScreenCaptureKit (whole device)
/// → hardware downscale (VideoToolbox) → LiveKit.
/// LiveKit's built-in in-app capturer sends ReplayKit frames at full screen resolution (1179×2556),
/// which on a weak uplink makes large frames queue for seconds before they are sent.
/// Owning the frame here also gives the place where sensitive fields can be masked before encoding.
final class AppScreenSource {
    /// The video track to publish; frames are pushed into it through `capturer`.
    let track: LocalVideoTrack
    private let capturer: BufferCapturer
    private let maxLongSide: Int
    private let minFrameInterval: Double

    /// Hardware scaler plus a buffer pool sized for the current output, recreated when the size changes.
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    /// Host time of the last frame handed to LiveKit, and that frame, for pacing and the idle resend.
    private var lastFrameTime: Double = 0
    private var lastOutput: CVPixelBuffer?
    private var resendTimer: DispatchSourceTimer?
    /// The ScreenCaptureKit capture when used; typed AnyObject because DeviceCapture exists only on iOS 27+.
    private var deviceCapture: AnyObject?
    /// Frame counters for the periodic log line; `sentTotal` is never reset.
    private var counters = (received: 0, sent: 0, resent: 0, lastReport: 0.0, sentTotal: 0)
    private var mode = "app"
    private var loggedFirstFrame = false
    /// Newest frame waiting for its pacing slot, and whether a delayed send is already scheduled.
    private var pending: (buffer: CVPixelBuffer, time: CMTime)?
    private var pendingScheduled = false
    private var activeObserver: NSObjectProtocol?
    /// Serial queue that owns all frame state above; capture callbacks hop onto it.
    private let queue = DispatchQueue(label: "app-screen-source")
    /// Screen size in points, the coordinate space of `SupportMask` rects.
    private let screenSize = UIScreen.main.bounds.size

    private init(track: LocalVideoTrack, capturer: BufferCapturer, maxLongSide: Int, fps: Int) {
        self.track = track
        self.capturer = capturer
        self.maxLongSide = maxLongSide
        minFrameInterval = 1.0 / Double(max(fps, 1))
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    /// Creates a buffer-fed screen-share track. The dimensions given here are only an initial hint;
    /// the real size comes from the first frame.
    static func make(maxLongSide: Int, fps: Int) async -> AppScreenSource? {
        let track = await LocalVideoTrack.createBufferTrack(
            source: .screenShareVideo,
            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(maxLongSide), height: Int32(maxLongSide)), fps: fps)
        )
        guard let capturer = track.capturer as? BufferCapturer else { return nil }
        return AppScreenSource(track: track, capturer: capturer, maxLongSide: maxLongSide, fps: fps)
    }

    /// Starts capture and returns once the first frame reached the track:
    /// LiveKit needs one frame to know the dimensions before the track can be published.
    func start(device: Bool, api: CaptureAPI = .current) async throws {
        let useScreenCaptureKit = api.usesScreenCaptureKit(device: device)
        mode = (device ? "device" : "app") + (useScreenCaptureKit ? "·ScreenCaptureKit" : "·ReplayKit")
        DiagLog.shared.log("capture", "\(mode) start · maxLongSide \(maxLongSide) · fps cap \(Int((1 / minFrameInterval).rounded()))")
        if useScreenCaptureKit, #available(iOS 27.0, *) {
            #if canImport(ScreenCaptureKit)
            try await startScreenCaptureKit(appOnly: !device)
            #endif
        } else {
            if device {
                // Whole-device capture before iOS 27 needs a Broadcast Upload Extension with an App Group.
                DiagLog.shared.log("capture", "device mode without ScreenCaptureKit → broadcast extension not in this PoC, capturing this app only")
            }
            try await startApp()
            observeReturnToForeground()
        }
        startResendTimer()
        DiagLog.shared.log("capture", "\(mode) started")
    }

    /// ReplayKit stops delivering frames when the app leaves the foreground (lock, call, app switch)
    /// and does not resume by itself; restart it once the app is active again.
    private func observeReturnToForeground() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let silent = self.queue.sync { CACurrentMediaTime() - self.lastFrameTime > 0.5 }
                guard silent, self.activeObserver != nil else { return }
                DiagLog.shared.log("capture", "app active again and ReplayKit is silent → restarting it")
                RPScreenRecorder.shared().stopCapture { _ in
                    Task {
                        do {
                            try await self.startApp()
                            DiagLog.shared.log("capture", "ReplayKit restarted")
                        } catch {
                            DiagLog.shared.log("capture", "ReplayKit restart failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// ReplayKit may accept the start and then never deliver a frame (the iOS Simulator does this),
    /// which would leave the session "streaming" with no picture; give up after a few seconds instead.
    private func startApp() async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            RPScreenRecorder.shared().startCapture(handler: { [weak self] sampleBuffer, type, error in
                guard error == nil, type == .video, let self,
                      let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                self.queue.sync { self.deliver(source, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
                if once.claim() { continuation.resume() }
            }, completionHandler: { error in
                if let error, once.claim() { continuation.resume(throwing: error) }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard once.claim() else { return }
                DiagLog.shared.log("capture", "ReplayKit gave no frame in 10 s → giving up")
                RPScreenRecorder.shared().stopCapture { _ in }
                continuation.resume(throwing: CaptureTimeout())
            }
        }
    }

    /// Thrown when ReplayKit starts but never delivers a frame.
    private struct CaptureTimeout: LocalizedError {
        var errorDescription: String? { "screen capture produced no picture (not supported on the iOS Simulator)" }
    }

    #if canImport(ScreenCaptureKit)
    @available(iOS 27.0, *)
    /// Starts DeviceCapture (system picker + SCStream) and waits up to 3 s for the first frame.
    private func startScreenCaptureKit(appOnly: Bool) async throws {
        let firstFrame = AsyncStream<Void>.makeStream()
        let capture = DeviceCapture(
            maxLongSide: maxLongSide,
            appOnly: appOnly,
            onFrame: { [weak self] buffer, time in
                guard let self else { return }
                self.queue.sync { self.deliver(buffer, at: time) }
                firstFrame.continuation.yield()
            },
            onStop: { [weak self] error in self?.onStop?(error) }
        )
        deviceCapture = capture
        try await capture.start()
        // A static screen may not produce a frame on its own; wait briefly, the resend timer covers the rest.
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in firstFrame.stream { return } }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        firstFrame.continuation.finish()
    }
    #endif

    /// Called when the system ends a whole-device capture (e.g. the user stopped it from Control Center).
    var onStop: ((Error) -> Void)?

    /// Stops whichever capture is running and the resend timer; the track itself is unpublished by the engine.
    func stop() {
        DiagLog.shared.log("capture", "\(mode) stop · sent \(counters.sentTotal) frames in total")
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        resendTimer?.cancel()
        resendTimer = nil
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *), let capture = deviceCapture as? DeviceCapture {
            deviceCapture = nil
            Task { await capture.stop() }
            return
        }
        #endif
        RPScreenRecorder.shared().stopCapture { _ in }
    }

    /// Re-sends the last frame once a second while the screen is still, so a viewer who joins
    /// or asks for a key frame does not wait for the next change on screen.
    private func startResendTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let output = self.lastOutput,
                  CACurrentMediaTime() - self.lastFrameTime >= 1 else { return }
            self.capturer.capture(output, timeStampNs: Int64(CACurrentMediaTime() * Double(NSEC_PER_SEC)))
            self.counters.resent += 1
            self.reportIfDue()
        }
        timer.resume()
        resendTimer = timer
    }

    /// Entry point for every captured frame (on `queue`): logs, then paces it to the profile's frame rate.
    private func deliver(_ source: CVPixelBuffer, at time: CMTime) {
        counters.received += 1
        if !loggedFirstFrame {
            loggedFirstFrame = true
            DiagLog.shared.log("capture", "first frame \(CVPixelBufferGetWidth(source))×\(CVPixelBufferGetHeight(source)) format \(Self.fourCC(CVPixelBufferGetPixelFormatType(source))) planes \(CVPixelBufferGetPlaneCount(source)) bytesPerRow \(CVPixelBufferGetBytesPerRowOfPlane(source, 0))")
        }
        reportIfDue()
        // Keep to the profile's frame rate without losing the last frame of a motion: a frame that
        // comes too early waits for its slot and is replaced by any newer one. Dropping it instead
        // (the screen refreshes at up to 120 Hz) left the final state of a scroll on screen only
        // after the next change or the 1-second resend.
        let wait = minFrameInterval - (CACurrentMediaTime() - lastFrameTime)
        if lastFrameTime > 0, wait > 0 {
            pending = (source, time)
            if !pendingScheduled {
                pendingScheduled = true
                queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self else { return }
                    self.pendingScheduled = false
                    if let frame = self.pending {
                        self.pending = nil
                        self.send(frame.buffer, at: frame.time)
                    }
                }
            }
            return
        }
        pending = nil
        send(source, at: time)
    }

    /// Downscales, masks and hands one frame to LiveKit.
    private func send(_ source: CVPixelBuffer, at time: CMTime) {
        lastFrameTime = CACurrentMediaTime()
        // Masks are painted into our own copy, never into the system's capture buffer.
        let masks = SupportMask.shared.current
        let output = downscaled(source, copy: !masks.isEmpty) ?? source
        if !masks.isEmpty, output !== source {
            SupportMask.paint(masks, into: output, screen: screenSize)
        } else if !masks.isEmpty {
            // No copy could be made: do not send the frame with the secret in it.
            return
        }
        lastOutput = output
        counters.sent += 1
        if counters.sentTotal == 0 {
            DiagLog.shared.log("capture", "first sent frame \(CVPixelBufferGetWidth(output))×\(CVPixelBufferGetHeight(output))\(output === source ? " (not downscaled)" : "")")
        }
        counters.sentTotal += 1
        capturer.capture(output, timeStampNs: Int64(CMTimeGetSeconds(time) * Double(NSEC_PER_SEC)))
    }

    /// Every 5 s: how many frames the system gave, how many went to the encoder, how many were repeats.
    private func reportIfDue() {
        let now = CACurrentMediaTime()
        if counters.lastReport == 0 { counters.lastReport = now; return }
        guard now - counters.lastReport >= 5 else { return }
        let seconds = now - counters.lastReport
        DiagLog.shared.log("capture", String(format: "%@ last %.0fs: in %.1f fps, out %.1f fps, resent %d", mode, seconds,
                                             Double(counters.received) / seconds, Double(counters.sent) / seconds, counters.resent))
        counters = (0, 0, 0, now, counters.sentTotal)
    }

    /// Pixel format code as four characters, e.g. "420f", for the log.
    private static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Returns a scaled copy no longer than `maxLongSide`, or nil when no scaling is needed and no copy
    /// was asked for (or scaling failed). `copy` forces a new buffer even at scale 1, so masks can be painted.
    private func downscaled(_ source: CVPixelBuffer, copy: Bool = false) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(maxLongSide) / Double(max(width, height)))
        guard scale < 1 || copy, let transfer else { return nil }

        // Multiples of 16 suit the hardware H.264 encoder.
        let targetWidth = Int((Double(width) * scale / 16).rounded()) * 16
        let targetHeight = Int((Double(height) * scale / 16).rounded()) * 16
        if pool == nil || poolSize != (targetWidth, targetHeight) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: targetWidth,
                kCVPixelBufferHeightKey: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (targetWidth, targetHeight)
        }
        guard let pool else { return nil }

        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else {
            DiagLog.shared.log("capture", "downscale failed, sending the original frame")
            return nil
        }
        return destination
    }

    deinit {
        resendTimer?.cancel()
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }
}

/// Which system API captures the screen. ReplayKit's screen sharing is deprecated in the iOS 27 SDK in
/// favour of ScreenCaptureKit, but ELD supports iOS 17, so both are kept:
/// - auto: ScreenCaptureKit on iOS 27+, ReplayKit before.
/// - replayKit / screenCaptureKit: forced, to compare both on one iOS 27 device.
/// Whole-device capture before iOS 27 would need a Broadcast Upload Extension (ReplayKit), not in this PoC.
enum CaptureAPI: String, CaseIterable, Identifiable {
    case auto
    case replayKit = "replaykit"
    case screenCaptureKit = "screencapturekit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto (ScreenCaptureKit on iOS 27+)"
        case .replayKit: "ReplayKit"
        case .screenCaptureKit: "ScreenCaptureKit (iOS 27+)"
        }
    }

    /// UserDefaults key; the choice survives relaunches.
    private static let key = "captureAPI"

    static var current: CaptureAPI {
        get { UserDefaults.standard.string(forKey: key).flatMap(CaptureAPI.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Resolves the setting for one capture: ScreenCaptureKit needs both the framework and iOS 27.
    func usesScreenCaptureKit(device: Bool) -> Bool {
        #if !canImport(ScreenCaptureKit)
        return false
        #endif
        guard #available(iOS 27.0, *) else { return false }
        // In-app ReplayKit cannot capture other apps, so device mode on iOS 27 always uses ScreenCaptureKit.
        return device || self != .replayKit
    }
}

/// True for the first caller only; safe across the threads ReplayKit calls back on.
private final class OnceFlag {
    private var used = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

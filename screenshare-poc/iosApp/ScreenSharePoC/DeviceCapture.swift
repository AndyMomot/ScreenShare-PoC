// The iOS Simulator SDK has no ScreenCaptureKit; there the app falls back to ReplayKit.
#if canImport(ScreenCaptureKit)
import CoreMedia
import ScreenCaptureKit
import UIKit

/// Screen capture through ScreenCaptureKit (iOS 27+): the whole device or only this app, without a broadcast extension.
/// Frames go to our own pipeline as whole buffers: LiveKit's ScreenCaptureKit capturer crops each
/// frame by the reported content rectangle, and on iOS that crop can run past the buffer and crash
/// inside libyuv (SplitUVRow_NEON).
@available(iOS 27.0, *)
final class DeviceCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    /// Output frame size requested from ScreenCaptureKit, in pixels.
    private let width: Int
    private let height: Int
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let onStop: (Error) -> Void
    private let appOnly: Bool
    /// Queue on which ScreenCaptureKit delivers frames; `onFrame` runs on it.
    private let queue = DispatchQueue(label: "device-capture")
    private var stream: SCStream?
    /// Pending picker answer; touched only on the main thread.
    private var pick: CheckedContinuation<SCContentFilter, Error>?

    /// - Parameter maxLongSide: the long side of delivered frames; the system scales to it.
    /// - Parameter appOnly: true offers only this app in the system picker; false lets the driver share the whole screen.
    init(maxLongSide: Int, appOnly: Bool = false, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void, onStop: @escaping (Error) -> Void) {
        self.appOnly = appOnly
        let native = UIScreen.main.nativeBounds.size
        let scale = min(1, Double(maxLongSide) / Double(max(native.width, native.height)))
        // Even sizes keep the 4:2:0 chroma planes whole.
        width = Int((Double(native.width) * scale / 2).rounded()) * 2
        height = Int((Double(native.height) * scale / 2).rounded()) * 2
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Shows the system picker, then starts an SCStream for what the driver chose. Throws if the picker is cancelled or fails.
    func start() async throws {
        DiagLog.shared.log("capture", "picker: presenting (asked size \(width)×\(height))")
        let filter = try await presentPicker()
        DiagLog.shared.log("capture", "picker: content selected")
        await releasePicker()
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        DiagLog.shared.log("capture", "SCStream started")
    }

    /// Stops the stream; safe to call when nothing is running.
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
    }

    // MARK: - Picker

    @MainActor
    /// Bridges the delegate-based picker to async/await: the observer callbacks resume the stored continuation.
    private func presentPicker() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw CaptureError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pick = continuation
            picker.add(self)
            picker.isActive = true
            if appOnly { picker.presentForCurrentApplication() } else { picker.present() }
        }
    }

    @MainActor
    /// Deactivates the picker and unregisters this observer so the next session starts clean.
    private func releasePicker() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
    }

    /// Resumes the picker continuation once, on the main thread; later callbacks find it nil and are ignored.
    private func finishPick(_ result: Result<SCContentFilter, Error>) {
        DispatchQueue.main.async {
            let continuation = self.pick
            self.pick = nil
            continuation?.resume(with: result)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finishPick(.success(filter))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DiagLog.shared.log("capture", "picker: cancelled by the user")
        finishPick(.failure(CaptureError.cancelled))
        DispatchQueue.main.async { self.releasePicker() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DiagLog.shared.log("capture", "picker: failed \(error)")
        finishPick(.failure(error))
        DispatchQueue.main.async { self.releasePicker() }
    }

    // MARK: - Stream

    /// Forwards only complete frames; idle/blank status buffers carry no new image.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// The system ended the stream (lock, call, user stopped it); the owner decides whether to pause or end.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagLog.shared.log("capture", "SCStream stopped by the system: \(error)")
        self.stream = nil
        onStop(error)
    }

    /// Errors the capture adds on top of ScreenCaptureKit's own.
    enum CaptureError: LocalizedError {
        case unavailable, cancelled
        var errorDescription: String? {
            switch self {
            case .unavailable: "Screen capture is not available on this device"
            case .cancelled: "Screen share cancelled"
            }
        }
    }
}
#endif

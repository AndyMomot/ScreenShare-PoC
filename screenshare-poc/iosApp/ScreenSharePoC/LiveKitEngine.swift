import Foundation
import LiveKit
import UIKit
import Shared

/// iOS side of ScreenShareEngine: LiveKit room for video + data, capture, command execution.
final class LiveKitEngine: NSObject, ScreenShareEngine, RoomDelegate {
    let room = Room()
    private let executor = CommandExecutor()

    var profile: StreamProfile = .smooth
    private var currentMode: CaptureMode?
    private var appSource: AppScreenSource?
    private var appPublication: LocalTrackPublication?

    var onMessage: ((String) -> Void)?
    var onConnectionState: ((ConnectionState) -> Void)?
    var onLog: ((String) -> Void)?
    /// iOS stopped the capture on its own (whole-device capture ends on lock or a call).
    var onCaptureInterrupted: (() -> Void)?
    var onCaptureStarted: (() -> Void)?
    var onCaptureFailed: ((String) -> Void)?

    override init() {
        super.init()
        room.add(delegate: self)
    }

    var connectionState: ConnectionState { room.connectionState }

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }

    func disconnect() async {
        await room.disconnect()
    }

    // MARK: - ScreenShareEngine (called by SessionController on the main thread)

    func sendMessage(json: String, reliable: Bool) {
        let data = Data(json.utf8)
        log("→ \(json)")
        Task {
            do {
                try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: reliable))
            } catch {
                log("send failed: \(error.localizedDescription)")
            }
        }
    }

    func startCapture(mode: CaptureMode) {
        currentMode = mode
        let device = mode == CaptureMode.device
        if device, #unavailable(iOS 27.0) {
            log("Device mode needs iOS 27 (ScreenCaptureKit) or a broadcast extension; falling back to app capture")
        }
        // Both modes run through our own frame path. Device mode: ScreenCaptureKit (iOS 27+) with the
        // system picker that can select the whole device; app mode: ReplayKit, this app only.
        let profile = self.profile
        Task {
            do {
                try await startAppSource(profile: profile, device: device)
                log("capture started (\(device ? "device" : "app"), \(profile.title))")
                startSenderStats()
                // The task runs off the main thread; the session rules and SwiftUI state live on main.
                await MainActor.run { onCaptureStarted?() }
            } catch {
                log("capture failed: \(error.localizedDescription)")
                await MainActor.run { onCaptureFailed?(error.localizedDescription) }
            }
        }
    }

    /// Our own downscaled frames instead of LiveKit's capturers (full-resolution in app mode,
    /// crashing crop in ScreenCaptureKit mode).
    private func startAppSource(profile: StreamProfile, device: Bool) async throws {
        guard let source = await AppScreenSource.make(maxLongSide: profile.maxLongSide, fps: profile.captureOptions.fps) else {
            throw LiveKitError(.invalidState, message: "buffer capturer unavailable")
        }
        source.onStop = { [weak self] error in
            DispatchQueue.main.async {
                self?.log("system stopped the capture: \(error.localizedDescription)")
                self?.onCaptureInterrupted?()
            }
        }
        try await source.start(device: device)
        appSource = source
        appPublication = try await room.localParticipant.publish(videoTrack: source.track, options: profile.publishOptions)
    }

    /// Starts the capture again in the same mode after iOS stopped it; asks the driver again.
    func restartCapture() {
        guard let mode = currentMode else { return }
        let source = appSource
        let publication = appPublication
        appSource = nil
        appPublication = nil
        source?.stop()
        Task {
            if let publication { try? await room.localParticipant.unpublish(publication: publication) }
            startCapture(mode: mode)
        }
    }

    func stopCapture() {
        currentMode = nil
        statsTask?.cancel()
        if let source = appSource {
            appSource = nil
            source.stop()
            let publication = appPublication
            appPublication = nil
            Task {
                if let publication { try? await room.localParticipant.unpublish(publication: publication) }
                log("capture stopped")
            }
            return
        }
        Task {
            do {
                try await room.localParticipant.setScreenShare(enabled: false)
                log("capture stopped")
            } catch {
                log("stop failed: \(error.localizedDescription)")
            }
        }
    }

    func showPointer(x: Double, y: Double) {
        PointerOverlay.shared.show(x: x, y: y)
    }

    func execute(command: ControlCommand) -> String? {
        DiagLog.shared.log("control", "command \(command) · app state \(UIApplication.shared.applicationState.rawValue) (0 active, 1 inactive, 2 background)")
        let failure = executor.execute(command)
        log("exec \(command) → \(failure ?? "ok")")
        return failure
    }

    // MARK: - RoomDelegate

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let text = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { self.onMessage?(text) }
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        DispatchQueue.main.async { self.onConnectionState?(connectionState) }
    }

    // MARK: - Sender statistics (diagnostics for the support page)

    private var statsTask: Task<Void, Never>?

    /// Once a second sends the encoder's own view to the support page: what limits quality
    /// (bandwidth or CPU), the target bitrate, uplink estimate, send delay and loss reported by the server.
    private func startSenderStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var reporting: Track?
            var previous: OutboundRtpStreamStatistics?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let track = self.room.localParticipant.localVideoTracks.first?.track else { continue }
                if reporting !== track {
                    await track.set(reportStatistics: true)
                    reporting = track
                    previous = nil
                    continue
                }
                guard let stats = track.statistics,
                      let out = stats.outboundRtpStream.max(by: { ($0.bytesSent ?? 0) < ($1.bytesSent ?? 0) }) else { continue }
                defer { previous = out }
                guard let prev = previous else { continue }

                let seconds = max((out.timestamp - prev.timestamp) / 1_000_000, 0.001) // timestamps are in microseconds
                let frames = Double((out.framesEncoded ?? 0) - min(out.framesEncoded ?? 0, prev.framesEncoded ?? 0))
                let packets = Double((out.packetsSent ?? 0) - min(out.packetsSent ?? 0, prev.packetsSent ?? 0))
                let remote = stats.remoteInboundRtpStream.first
                let pair = stats.iceCandidatePair.first { $0.nominated == true }

                var report: [String: Any] = [
                    "type": "sender_stats",
                    "kbps": Double((out.bytesSent ?? 0) &- (prev.bytesSent ?? 0)) * 8 / seconds / 1000,
                    "retransmitKbps": Double((out.retransmittedBytesSent ?? 0) &- (prev.retransmittedBytesSent ?? 0)) * 8 / seconds / 1000,
                    "fps": out.framesPerSecond ?? frames / seconds,
                    "width": out.frameWidth ?? 0,
                    "height": out.frameHeight ?? 0,
                    "limitation": out.qualityLimitationReason?.rawValue ?? "?",
                    "encoder": out.encoderImplementation ?? "?",
                ]
                if let target = out.targetBitrate { report["targetKbps"] = target / 1000 }
                if frames > 0 { report["encodeMs"] = ((out.totalEncodeTime ?? 0) - (prev.totalEncodeTime ?? 0)) / frames * 1000 }
                if packets > 0 { report["sendDelayMs"] = ((out.totalPacketSendDelay ?? 0) - (prev.totalPacketSendDelay ?? 0)) / packets * 1000 }
                if let lost = remote?.fractionLost { report["lossPercent"] = lost * 100 }
                if let rtt = remote?.roundTripTime { report["rttMs"] = rtt * 1000 }
                if let uplink = pair?.availableOutgoingBitrate { report["uplinkKbps"] = uplink / 1000 }

                if let data = try? JSONSerialization.data(withJSONObject: report) {
                    try? await self.room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: false))
                }
            }
        }
    }

    private func log(_ line: String) {
        DispatchQueue.main.async { self.onLog?(line) }
    }
}

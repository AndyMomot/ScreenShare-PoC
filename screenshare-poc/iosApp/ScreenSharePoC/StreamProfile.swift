import LiveKit

/// Encoding presets to compare on the device: smoothness on motion vs sharpness vs traffic.
enum StreamProfile: String, CaseIterable, Identifiable {
    /// 720p, up to 30 fps, keeps frame rate under load: swipes and transitions stay fluid.
    case smooth
    /// LiveKit's screen-share default: 1080p, 15 fps, keeps resolution under load: text is crisp, motion stutters.
    case sharp
    /// 720p, 10 fps, low bitrate: for mobile networks and traffic limits.
    case economy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: "Smooth · 720p 30fps"
        case .sharp: "Sharp · 1080p 15fps"
        case .economy: "Economy · 720p 10fps"
        }
    }

    var captureOptions: (dimensions: Dimensions, fps: Int) {
        switch self {
        case .smooth: (.h720_169, 30)
        case .sharp: (.h1080_169, 15)
        case .economy: (.h720_169, 10)
        }
    }

    /// H.264 is encoded by the hardware encoder; VP8 (WebRTC's fallback) is software and adds latency and heat.
    /// Longest side of the frame we send in app mode (portrait screen: this is the height).
    var maxLongSide: Int {
        switch self {
        case .smooth: 1280
        case .sharp: 1920
        case .economy: 960
        }
    }

    var publishOptions: VideoPublishOptions {
        switch self {
        case .smooth:
            VideoPublishOptions(
                screenShareEncoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30),
                simulcast: false,
                preferredCodec: .h264,
                degradationPreference: .maintainFramerate
            )
        case .sharp:
            VideoPublishOptions(
                screenShareEncoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 15),
                simulcast: true,
                preferredCodec: .h264,
                degradationPreference: .maintainResolution
            )
        case .economy:
            VideoPublishOptions(
                screenShareEncoding: VideoEncoding(maxBitrate: 400_000, maxFps: 10),
                simulcast: false,
                preferredCodec: .h264,
                degradationPreference: .maintainFramerate
            )
        }
    }
}

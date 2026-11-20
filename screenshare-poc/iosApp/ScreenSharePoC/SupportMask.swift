import CoreVideo
import SwiftUI
import UIKit

/// Areas of this app's screen the support person must not see (passwords, PINs, card numbers).
/// They are painted black in every frame before encoding, so they never leave the phone.
/// `.privacySensitive()` does not help here: it redacts widgets and the lock screen, not screen capture.
final class SupportMask {
    static let shared = SupportMask()

    /// Masked areas keyed by the view that registered them. Written on the main thread by SwiftUI,
    /// read on the capture queue for every frame, hence the lock.
    private var rects: [UUID: CGRect] = [:]
    private var appActive = true
    private let lock = NSLock()

    private init() {
        let center = NotificationCenter.default
        // Track foreground state: the app's own rects mean nothing once another app covers the screen.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setActive(true)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setActive(false)
        }
    }

    /// Registers, moves (non-nil) or removes (nil) the mask area of one view.
    func set(_ id: UUID, _ rect: CGRect?) {
        lock.lock(); defer { lock.unlock() }
        rects[id] = rect
    }

    /// Rects in screen points; empty while another app is in front (whole-device capture).
    var current: [CGRect] {
        lock.lock(); defer { lock.unlock() }
        return appActive ? Array(rects.values) : []
    }

    private func setActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        appActive = active
    }

    /// Paints the rects black in a 4:2:0 bi-planar frame that shows the whole screen.
    static func paint(_ rects: [CGRect], into buffer: CVPixelBuffer, screen: CGSize) {
        guard !rects.isEmpty, CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let sx = Double(width) / screen.width, sy = Double(height) / screen.height
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // Video-range luma starts at 16, so 0 would be out of range there; neutral chroma (128) makes it gray-free black.
        let black: UInt8 = fullRange ? 0 : 16

        for rect in rects {
            // Chroma is half resolution: keep edges even so both planes cover the same area.
            let x0 = max(0, Int(rect.minX * sx) & ~1), y0 = max(0, Int(rect.minY * sy) & ~1)
            let x1 = min(width, (Int((rect.maxX * sx).rounded(.up)) + 1) & ~1)
            let y1 = min(height, (Int((rect.maxY * sy).rounded(.up)) + 1) & ~1)
            guard x1 > x0, y1 > y0,
                  let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { continue }
            let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in y0..<y1 {
                memset(luma + y * lumaRow + x0, Int32(black), x1 - x0)
            }
            for y in (y0 / 2)..<(y1 / 2) {
                memset(chroma + y * chromaRow + x0, 128, x1 - x0) // Cb,Cr pairs: x0 is even
            }
        }
    }
}

/// Reports the view's global frame to `SupportMask` while it is on screen and removes it when it disappears.
/// The frame is in window points, which match the screen points the frame pipeline scales from.
private struct HiddenFromSupport: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { SupportMask.shared.set(id, proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in SupportMask.shared.set(id, frame) }
                }
            )
            .onDisappear { SupportMask.shared.set(id, nil) }
    }
}

extension View {
    /// Blacks this view out in the screen shared with support.
    func hiddenFromSupport() -> some View { modifier(HiddenFromSupport()) }
}

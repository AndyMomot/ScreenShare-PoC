import UIKit

/// A pass-through window above the app that shows where support is pointing.
/// It is part of the app's own windows, so the support page sees the pointer echoed in the stream.
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var window: UIWindow?
    private let dot = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
    private var hideWork: DispatchWorkItem?

    func show(x: Double, y: Double) {
        guard let window = ensureWindow() else { return }
        dot.center = CGPoint(x: x * window.bounds.width, y: y * window.bounds.height)
        dot.alpha = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.dot.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func ensureWindow() -> UIWindow? {
        if let window { return window }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return nil
        }
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        overlay.rootViewController = root

        dot.layer.cornerRadius = 18
        dot.layer.borderWidth = 3
        dot.layer.borderColor = UIColor.white.cgColor
        dot.backgroundColor = UIColor.systemRed.withAlphaComponent(0.55)
        dot.alpha = 0
        root.view.addSubview(dot)

        overlay.isHidden = false
        window = overlay
        return overlay
    }
}

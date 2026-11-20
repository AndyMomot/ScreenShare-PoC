import Shared
import UIKit
import WebKit

/// Executes support commands inside this app; in App Store mode with public APIs only (see `ControlMode`).
/// There is no public way to inject touches, so each command is mapped to the action it means:
/// UIKit controls get their actions sent, SwiftUI content is activated through accessibility.
final class CommandExecutor {
    /// The last web view a tap went into: text typed next goes to its focused element.
    private weak var lastWebView: WKWebView?

    init() {
        // The accessibility switch acts on this process only, so a stored Full mode is applied again at launch.
        if ControlMode.current == .full { AccessibilityEnabler.set(true) }
    }

    /// Runs one command on the main thread; returns nil on success or a short reason shown on the support page.
    func execute(_ command: ControlCommand) -> String? {
        guard let window = Self.keyWindow() else { return "no key window" }
        if let tap = command as? CmdTap {
            return tapAt(point(tap.x, tap.y, in: window), in: window)
        }
        if let swipe = command as? CmdSwipe {
            return swipeFrom(point(swipe.x1, swipe.y1, in: window), to: point(swipe.x2, swipe.y2, in: window), in: window)
        }
        if let text = command as? CmdText {
            return insert(text.value)
        }
        if command is CmdBack {
            return goBack(in: window)
        }
        return "unsupported command"
    }

    /// The app's key window; commands use its coordinate space (normalized coordinates map to its bounds).
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    // MARK: - Tap

    /// Walks up from the hit-tested view and handles the first thing it recognises: text input, web view,
    /// alert button, UIKit control. Anything else is treated as SwiftUI content (full mode only).
    private func tapAt(_ p: CGPoint, in window: UIWindow) -> String? {
        let hit = window.hitTest(p, with: nil)
        Self.trace("tap at (\(Int(p.x)), \(Int(p.y))) of \(Int(window.bounds.width))×\(Int(window.bounds.height)) · hit chain: \(Self.chain(from: hit))")

        var view = hit
        while let current = view {
            // Text fields are UIControls too: focus them instead of sending a tap action.
            if current is UITextField || current is UITextView {
                Self.trace("→ focus \(type(of: current))")
                current.becomeFirstResponder()
                return nil
            }
            if let webView = current as? WKWebView {
                return tapInWeb(webView, at: window.convert(p, to: webView))
            }
            // Alert buttons are private UIKit views, recognisable only by class name.
            if String(describing: type(of: current)).contains("AlertControllerActionView") {
                guard ControlMode.current == .full else {
                    Self.trace("alert button: blocked in App Store mode")
                    return ControlMode.blockedReason("alert buttons")
                }
                return tapAlertAction(view: current, in: window)
            }
            if let control = current as? UIControl, control.isEnabled {
                Self.trace("→ UIControl \(type(of: control))")
                if let toggle = control as? UISwitch {
                    // A switch reacts to valueChanged, not touchUpInside; flip it the way a user tap would.
                    toggle.setOn(!toggle.isOn, animated: true)
                    toggle.sendActions(for: .valueChanged)
                } else {
                    // Buttons may listen to either event; sending both covers target/action and UIAction handlers.
                    control.sendActions(for: .touchUpInside)
                    control.sendActions(for: .primaryActionTriggered)
                }
                return nil
            }
            view = current.superview
        }

        // Without assistive technology SwiftUI exposes no element to activate, and turning it on takes a
        // private API: in the App Store build a SwiftUI button simply cannot be pressed remotely.
        guard ControlMode.current == .full else {
            Self.trace("SwiftUI element: blocked in App Store mode · hit chain: \(Self.chain(from: hit))")
            return ControlMode.blockedReason("SwiftUI buttons and list rows")
        }

        // SwiftUI content has no UIControl per button: activate an accessibility element under the point.
        // The smallest element is often a text label inside the button (it cannot activate), so try every
        // element under the point — buttons first, then from smallest to largest — until one activates.
        let candidates = Self.accessibilityElements(at: p, in: window)
        Self.trace("a11y candidates (\(candidates.count)):\n" + candidates.prefix(8).enumerated()
            .map { "   \($0.offset). \(Self.describe($0.element))" }.joined(separator: "\n"))
        for (index, element) in candidates.enumerated() where element.accessibilityActivate() {
            Self.trace("→ activated candidate \(index)")
            return nil
        }
        Self.trace("no candidate activated")
        if Self.selectCell(containing: hit) {
            Self.trace("→ selected list cell via delegate (may have no visible effect)")
            return nil
        }
        if let first = candidates.first {
            return "a11y element '\(first.accessibilityLabel ?? "?")' did not activate"
        }
        return "nothing tappable at point (hit: \(hit.map { String(describing: type(of: $0)) } ?? "nil"))"
    }

    // MARK: - Web content

    /// Taps inside a web page through the page itself: the element under the point gets focus and a click.
    private func tapInWeb(_ webView: WKWebView, at p: CGPoint) -> String? {
        lastWebView = webView
        let zoom = max(webView.scrollView.zoomScale, 0.01)
        // elementFromPoint takes CSS pixels relative to the viewport; at zoom 1 they equal points.
        let x = p.x / zoom, y = p.y / zoom
        let script = """
        (function() {
          var e = document.elementFromPoint(\(x), \(y));
          if (!e) return 'no element at point';
          if (e.focus) e.focus();
          e.click();
          return e.tagName + (e.id ? '#' + e.id : '') + ' "' + (e.innerText || e.value || '').slice(0, 30) + '"';
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            Self.trace("web tap at (\(Int(x)), \(Int(y))) css px → \(error.map { "error \($0.localizedDescription)" } ?? "\(result ?? "nil")")")
        }
        return nil
    }

    /// Appends text to the page's focused input and fires `input` so page scripts and frameworks notice the change.
    private func typeInWeb(_ webView: WKWebView, _ value: String) {
        // A JSON string literal is valid JavaScript and escapes quotes, backslashes and newlines alike.
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return }
        let literal = String(array.dropFirst().dropLast())
        let script = """
        (function() {
          var e = document.activeElement;
          if (!e || !('value' in e)) return 'no focused input in the page';
          e.value += \(literal);
          e.dispatchEvent(new Event('input', { bubbles: true }));
          return 'typed into ' + e.tagName + (e.id ? '#' + e.id : '');
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            Self.trace("web text → \(error.map { "error \($0.localizedDescription)" } ?? "\(result ?? "nil")")")
        }
    }

    // MARK: - Alerts

    /// Alert buttons are not UIControls and SwiftUI exposes no accessibility for them without
    /// assistive technology running. Find the action by its title and run it the way UIKit would:
    /// dismiss, then call its handler. Uses the private `handler` key — PoC only.
    private func tapAlertAction(view: UIView, in window: UIWindow) -> String? {
        let titles = Set(Self.labels(in: view))
        guard let alert = Self.topPresented(in: window) as? UIAlertController else {
            Self.trace("alert tap: no UIAlertController presented (labels \(titles))")
            return "alert not found"
        }
        guard let action = alert.actions.first(where: { titles.contains($0.title ?? "") }) else {
            Self.trace("alert tap: no action matches \(titles); actions \(alert.actions.map { $0.title ?? "" })")
            return "alert action not found"
        }
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let handler = (action.value(forKey: "handler") as AnyObject?).map { unsafeBitCast($0, to: Handler.self) }
        Self.trace("alert tap: '\(action.title ?? "")' style \(action.style.rawValue) · handler \(handler == nil ? "none" : "found")")
        alert.dismiss(animated: true) { handler?(action) }
        return nil
    }

    /// All label texts under a view; used to read an alert button's title.
    private static func labels(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text { result.append(text) }
        view.subviews.forEach { result += labels(in: $0) }
        return result
    }

    /// Topmost presented controller (sheet, alert, cover), or nil when nothing is presented over the root.
    private static func topPresented(in window: UIWindow) -> UIViewController? {
        guard var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top === window.rootViewController ? nil : top
    }

    /// Last resort for list rows: call the table/collection delegate's selection method directly.
    private static func selectCell(containing view: UIView?) -> Bool {
        var current = view
        while let v = current {
            if let cell = v as? UITableViewCell, let table = ancestor(of: cell, UITableView.self),
               let indexPath = table.indexPath(for: cell) {
                table.delegate?.tableView?(table, didSelectRowAt: indexPath)
                return true
            }
            if let cell = v as? UICollectionViewCell, let collection = ancestor(of: cell, UICollectionView.self),
               let indexPath = collection.indexPath(for: cell) {
                collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
                return true
            }
            current = v.superview
        }
        return false
    }

    /// Accessibility elements whose frame contains the point: buttons first, each group from smallest to largest.
    static func accessibilityElements(at p: CGPoint, in root: NSObject) -> [NSObject] {
        var found: [(element: NSObject, area: CGFloat)] = []

        func visit(_ node: NSObject, depth: Int) {
            // Depth cap protects against cyclic or pathological accessibility trees.
            guard depth < 80 else { return }
            if let view = node as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if node.isAccessibilityElement {
                let frame = node.accessibilityFrame
                if frame.contains(p) {
                    found.append((node, frame.width * frame.height))
                }
            }
            // Containers expose children either as an array or through the indexed accessibility API.
            if let elements = node.accessibilityElements as? [NSObject], !elements.isEmpty {
                elements.forEach { visit($0, depth: depth + 1) }
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
                        .forEach { visit($0, depth: depth + 1) }
                }
            }
            if let view = node as? UIView {
                view.subviews.forEach { visit($0, depth: depth + 1) }
            }
        }

        visit(root, depth: 0)
        var seen = Set<ObjectIdentifier>()
        let unique = found.filter { seen.insert(ObjectIdentifier($0.element)).inserted }
        let isButton = { (e: NSObject) in e.accessibilityTraits.contains(.button) }
        return unique.sorted { a, b in
            if isButton(a.element) != isButton(b.element) { return isButton(a.element) }
            return a.area < b.area
        }.map(\.element)
    }

    // MARK: - Swipe

    /// No public API injects a drag, so a swipe is translated into what it would do: close a sheet,
    /// or move the nearest scroll view's content by the swipe distance (clamped to its content).
    private func swipeFrom(_ start: CGPoint, to end: CGPoint, in window: UIWindow) -> String? {
        // A downward swipe on a sheet that has nothing scrolled closes it, like the system gesture.
        if end.y - start.y > 80, let sheet = Self.topPresented(in: window), !(sheet is UIAlertController),
           sheet.view.convert(sheet.view.bounds, to: window).contains(start) {
            let scroll = Self.scrollView(at: start, in: window)
            let atTop = scroll.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + 1 } ?? true
            if atTop, !sheet.isModalInPresentation {
                Self.trace("swipe: closing sheet \(type(of: sheet))")
                sheet.dismiss(animated: true)
                return nil
            }
        }
        var view = window.hitTest(start, with: nil)
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { break }
            view = current.superview
        }
        guard let scroll = view as? UIScrollView else {
            Self.trace("swipe: no scroll view · hit chain: \(Self.chain(from: window.hitTest(start, with: nil)))")
            return "no scroll view at start point"
        }

        let inset = scroll.adjustedContentInset
        var offset = scroll.contentOffset
        offset.x += start.x - end.x
        offset.y += start.y - end.y
        let maxX = max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let maxY = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        offset.x = min(max(offset.x, -inset.left), maxX)
        offset.y = min(max(offset.y, -inset.top), maxY)
        Self.trace("swipe: \(type(of: scroll)) offset \(Int(scroll.contentOffset.y)) → \(Int(offset.y)) (content \(Int(scroll.contentSize.height)))")
        scroll.setContentOffset(offset, animated: true)
        return nil
    }

    /// Nearest scrollable ancestor of the view under the point.
    private static func scrollView(at p: CGPoint, in window: UIWindow) -> UIScrollView? {
        var view = window.hitTest(p, with: nil)
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { return scroll }
            view = current.superview
        }
        return nil
    }

    // MARK: - Text

    /// Types into whatever has focus. The first responder is found with the nil-targeted action trick:
    /// UIKit delivers the action to the current first responder, which records itself.
    private func insert(_ value: String) -> String? {
        FirstResponder.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.poc_captureFirstResponder), to: nil, from: nil, for: nil)
        defer { FirstResponder.current = nil }
        Self.trace("text: first responder = \(FirstResponder.current.map { String(describing: type(of: $0)) } ?? "none")")
        if let webView = lastWebView, let responder = FirstResponder.current as? UIView, responder.isDescendant(of: webView) {
            typeInWeb(webView, value)
            return nil
        }
        guard let input = FirstResponder.current as? UIKeyInput else {
            if let webView = lastWebView, webView.window != nil {
                typeInWeb(webView, value)
                return nil
            }
            return "no focused text field (tap a field first)"
        }
        input.insertText(value)
        return nil
    }

    // MARK: - Back

    /// Back means: dismiss the topmost presented controller, otherwise pop the deepest navigation stack.
    private func goBack(in window: UIWindow) -> String? {
        guard let root = window.rootViewController else { return "no root view controller" }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        Self.trace("back: top controller \(type(of: top))")
        if top !== root {
            top.dismiss(animated: true)
            return nil
        }
        if let navigation = Self.deepestNavigation(in: root), navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
            return nil
        }
        return "nothing to go back from"
    }

    /// Searches children last-first (the visible tab/child is usually last) for a navigation stack that can pop.
    private static func deepestNavigation(in controller: UIViewController) -> UINavigationController? {
        for child in controller.children.reversed() {
            if let found = deepestNavigation(in: child) { return found }
        }
        if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 {
            return navigation
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Control diagnostics go to DiagLog, so failed remote taps can be analysed on the Mac.
    private static func trace(_ line: String) {
        DiagLog.shared.log("control", line)
    }

    /// Class names from a view up to five ancestors, for logs.
    private static func chain(from view: UIView?) -> String {
        var names: [String] = []
        var current = view
        while let v = current, names.count < 6 {
            names.append(String(describing: type(of: v)))
            current = v.superview
        }
        return names.isEmpty ? "nil" : names.joined(separator: " < ")
    }

    /// One-line summary of an accessibility element (class, label, value, traits, frame) for logs.
    private static func describe(_ element: NSObject) -> String {
        let frame = element.accessibilityFrame
        var traits: [String] = []
        let t = element.accessibilityTraits
        if t.contains(.button) { traits.append("button") }
        if t.contains(.staticText) { traits.append("text") }
        if t.contains(.header) { traits.append("header") }
        if t.contains(.selected) { traits.append("selected") }
        if t.contains(.notEnabled) { traits.append("disabled") }
        if t.contains(.adjustable) { traits.append("adjustable") }
        if t.contains(.tabBar) { traits.append("tabBar") }
        let actions = element.accessibilityCustomActions?.map(\.name).joined(separator: ",") ?? ""
        return "\(type(of: element)) '\(element.accessibilityLabel ?? "")' value='\(element.accessibilityValue ?? "")' "
            + "traits=[\(traits.joined(separator: ","))] frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
            + (actions.isEmpty ? "" : " actions=[\(actions)]")
    }

    // MARK: - Helpers

    /// Normalized 0..1 coordinates to window points.
    private func point(_ x: Double, _ y: Double, in window: UIWindow) -> CGPoint {
        CGPoint(x: x * window.bounds.width, y: y * window.bounds.height)
    }

    /// Nearest superview of the given type.
    private static func ancestor<T: UIView>(of view: UIView, _ type: T.Type) -> T? {
        var current = view.superview
        while let v = current {
            if let match = v as? T { return match }
            current = v.superview
        }
        return nil
    }
}

/// Scratch slot filled by `poc_captureFirstResponder` during `insert`.
private enum FirstResponder {
    static var current: UIResponder?
}

extension UIResponder {
    /// Sent with a nil target, so UIKit calls it on the current first responder. Prefixed to avoid name clashes.
    @objc func poc_captureFirstResponder() {
        FirstResponder.current = self
    }
}

/// SwiftUI builds its accessibility tree only while assistive technology is on, so without it
/// buttons in SwiftUI lists have no element to activate. The automation switch (what UI tests
/// use) turns it on for this process. Private API — PoC only, not for the App Store.
enum AccessibilityEnabler {
    static func set(_ enabled: Bool) {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else {
            DiagLog.shared.log("control", "accessibility: libAccessibility not loaded")
            return
        }
        typealias Setter = @convention(c) (Bool) -> Void
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(library, name) {
                unsafeBitCast(symbol, to: Setter.self)(enabled)
                DiagLog.shared.log("control", "accessibility: \(name)(\(enabled)) called")
            } else {
                DiagLog.shared.log("control", "accessibility: \(name) not found")
            }
        }
    }
}

/// Which remote control the app offers, to show side by side what passes App Review and what does not.
/// - appStore: public APIs only — UIKit controls, text fields, scrolling, web content, Back, pointer.
/// - full: adds SwiftUI buttons and system alert buttons through private APIs (rejected under guideline 2.5.1).
/// A real App Store build must not contain the private code at all, not just have it switched off.
enum ControlMode: String, CaseIterable, Identifiable {
    case appStore = "app_store"
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appStore: "App Store (public APIs)"
        case .full: "Full (private APIs)"
        }
    }

    /// UserDefaults key; the mode survives relaunches.
    private static let key = "controlMode"

    static var current: ControlMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(ControlMode.init) ?? .appStore }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            AccessibilityEnabler.set(newValue == .full)
            DiagLog.shared.log("control", "control mode → \(newValue.rawValue)")
        }
    }

    /// Failure text sent back to support when App Store mode refuses an action.
    static func blockedReason(_ what: String) -> String {
        "\(what) need a private API — not available in the App Store build"
    }
}

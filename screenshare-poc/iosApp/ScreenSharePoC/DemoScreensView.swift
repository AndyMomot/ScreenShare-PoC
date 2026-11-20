import AVFoundation
import SwiftUI
import UIKit
import VisionKit
import WebKit

/// The kinds of UI the ELD app has, to check what support sees and can control.
struct DemoScreensView: View {
    // Each presented UI lives in its own window/layer on iOS; these check what capture and control can reach.
    @State private var showAlert = false
    @State private var showSheet = false
    @State private var showDialog = false
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section("Presented UI") {
                    Button("Alert") { showAlert = true }
                    Button("Sheet") { showSheet = true }
                    Button("Confirmation dialog") { showDialog = true }
                    Button("Document scanner") { showScanner = true }
                }
                Section("Screens") {
                    NavigationLink("Tap targets (SwiftUI + UIKit)") { TapTargetsScreen() }
                    NavigationLink("Login form (SecureField)") { LoginFormScreen() }
                    NavigationLink("WebView") { WebViewScreen() }
                    NavigationLink("Camera preview") { CameraPreviewScreen() }
                    NavigationLink("Long list") { LongListScreen() }
                }
            }
            .navigationTitle("Screens")
            .alert("Demo alert", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Is this alert visible to support?")
            }
            .sheet(isPresented: $showSheet) {
                VStack(spacing: 16) {
                    Text("Demo sheet").font(.title.bold())
                    Button("Close") { showSheet = false }.buttonStyle(.borderedProminent)
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog("Demo dialog", isPresented: $showDialog) {
                Button("Option A") {}
                Button("Option B") {}
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { showScanner = false }.ignoresSafeArea()
            }
        }
    }
}

/// SwiftUI and UIKit controls side by side: remote taps reach them through different code paths in CommandExecutor.
struct TapTargetsScreen: View {
    @State private var swiftUITaps = 0
    @State private var toggle = false

    var body: some View {
        Form {
            Section("SwiftUI") {
                Button("SwiftUI button (\(swiftUITaps))") { swiftUITaps += 1 }
                Toggle("SwiftUI toggle", isOn: $toggle)
            }
            Section("UIKit") {
                UIKitButton().frame(height: 44)
            }
        }
        .navigationTitle("Tap targets")
    }
}

/// Plain UIButton with its own tap counter, to verify UIKit control events from remote taps.
private struct UIKitButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(configuration: .filled())
        var taps = 0
        button.setTitle("UIKit button (0)", for: .normal)
        button.addAction(UIAction { action in
            taps += 1
            (action.sender as? UIButton)?.setTitle("UIKit button (\(taps))", for: .normal)
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

/// Masking demo: the secure fields are blacked out in the stream, the login field is not.
struct LoginFormScreen: View {
    @State private var login = ""
    @State private var password = ""
    @State private var pin = ""

    var body: some View {
        Form {
            TextField("Login", text: $login)
            SecureField("Password", text: $password).hiddenFromSupport()
            SecureField("PIN", text: $pin).keyboardType(.numberPad).hiddenFromSupport()
        }
        .navigationTitle("Login form")
    }
}

/// Web content: a button and an input inside WKWebView, which UIKit hit-testing alone cannot press or fill.
struct WebViewScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadHTMLString("""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font-family:-apple-system;padding:24px">
        <h2>WebView content</h2>
        <button style="font-size:22px" onclick="this.innerText='Tapped '+(++window.n||(window.n=1))">Web button</button>
        <p><input style="font-size:20px" placeholder="Web input"></p>
        </body></html>
        """, baseURL: nil)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Live camera preview, to see how full-motion video survives the capture and encoding.
struct CameraPreviewScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> CameraPreviewUIView { CameraPreviewUIView() }
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

/// View whose backing layer is the camera preview layer.
final class CameraPreviewUIView: UIView {
    private let session = AVCaptureSession()

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        (layer as? AVCaptureVideoPreviewLayer)?.session = session
        (layer as? AVCaptureVideoPreviewLayer)?.videoGravity = .resizeAspectFill
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            // startRunning blocks, so it must not run on the main thread.
            DispatchQueue.global(qos: .userInitiated).async { self.configure() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { session.stopRunning() }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        session.startRunning()
    }
}

/// Long scrolling list, to try remote swipes.
struct LongListScreen: View {
    var body: some View {
        List(0..<200, id: \.self) { index in
            Text("Row \(index)")
        }
        .navigationTitle("Long list")
    }
}

/// System document scanner (a separate full-screen controller), closed on cancel, finish or error.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) { onFinish() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish() }
    }
}

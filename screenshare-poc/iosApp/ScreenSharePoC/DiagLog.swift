import Darwin
import Foundation
import UIKit

/// Test-run diagnostics. Every line goes to the Xcode console and, in batches, to the Mac's
/// `POST /log` (written to `logs/poc.log` next to the support page's lines).
/// Also samples the device (CPU, memory, temperature, battery) and records a crash for the next launch.
final class DiagLog {
    static let shared = DiagLog()

    /// The Mac to send lines to; set once the app knows the server.
    var host: String? {
        get { queue.sync { _host } }
        set { queue.async { self._host = newValue } }
    }

    // All mutable state below is touched only on `queue`; that serial queue is the lock.
    private var _host: String?
    private var pending: [String] = []
    private let queue = DispatchQueue(label: "diag-log")
    private var flushTimer: DispatchSourceTimer?
    private var sampleTimer: DispatchSourceTimer?
    /// Last CPU sample, to turn cumulative CPU seconds into a percentage over the sampling interval.
    private var previousCPU: (time: Double, cpu: Double)?
    /// Survives the crash in Documents; read and deleted on the next `start()`.
    private static let crashFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("last-crash.txt")

    private init() {}

    /// Called once at launch: crash handlers, report of the previous crash, system observers, flush and sample timers.
    func start() {
        installCrashHandlers()
        if let crash = try? String(contentsOf: Self.crashFile, encoding: .utf8) {
            log("crash", "previous run crashed:\n\(crash)")
            try? FileManager.default.removeItem(at: Self.crashFile)
        }
        let device = UIDevice.current
        log("app", "launch · \(device.model) iOS \(device.systemVersion) · screen \(UIScreen.main.nativeBounds.size) @\(UIScreen.main.scale)x")
        device.isBatteryMonitoringEnabled = true
        observeSystem()

        let flush = DispatchSource.makeTimerSource(queue: queue)
        flush.schedule(deadline: .now() + 1, repeating: 1)
        flush.setEventHandler { [weak self] in self?.flush() }
        flush.resume()
        flushTimer = flush

        let sample = DispatchSource.makeTimerSource(queue: queue)
        sample.schedule(deadline: .now() + 10, repeating: 10)
        sample.setEventHandler { [weak self] in self?.sampleDevice() }
        sample.resume()
        sampleTimer = sample
    }

    /// Prints the line and queues it for the Mac; keeps at most the last 2000 unsent lines.
    func log(_ tag: String, _ message: String) {
        let line = "\(Self.time()) [\(tag)] \(message)"
        print(line)
        queue.async {
            self.pending.append(line)
            if self.pending.count > 2000 { self.pending.removeFirst(self.pending.count - 2000) }
        }
    }

    // MARK: - Sending

    /// Runs on `queue` every second: posts all pending lines in one request, re-queues them in front on failure.
    private func flush() {
        guard !pending.isEmpty, let host = _host,
              let url = URL(string: "http://\(host):8080/log") else { return }
        let lines = pending
        pending.removeAll()
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["source": "ios", "lines": lines])
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard error != nil || (response as? HTTPURLResponse)?.statusCode != 204, let self else { return }
            // Mac not reachable: keep the lines for the next attempt.
            self.queue.async { self.pending.insert(contentsOf: lines, at: 0) }
        }.resume()
    }

    // MARK: - Device sampling

    /// Every 10 s: CPU %, memory footprint, thermal state, battery and Low Power Mode, to see what streaming costs.
    private func sampleDevice() {
        let now = CACurrentMediaTime()
        let cpu = Self.cpuSeconds()
        var cpuText = "?"
        if let previous = previousCPU, now > previous.time {
            cpuText = String(format: "%.0f%%", (cpu - previous.cpu) / (now - previous.time) * 100)
        }
        previousCPU = (now, cpu)
        let memory = Self.memoryFootprintMB().map { String(format: "%.0f MB", $0) } ?? "?"
        let device = UIDevice.current
        let battery = device.batteryLevel < 0 ? "?" : String(format: "%.0f%%", device.batteryLevel * 100)
        log("device", "cpu \(cpuText) (100% = one core) · memory \(memory) · thermal \(Self.thermal(ProcessInfo.processInfo.thermalState)) · battery \(battery) \(Self.batteryState(device.batteryState)) · lowPower \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    /// Total user + system CPU time consumed by this process so far.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// `phys_footprint` is the figure iOS uses for memory limits (what Xcode's memory gauge shows).
    private static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "unknown"
        }
    }

    private static func batteryState(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: ""
        }
    }

    // MARK: - System events

    /// Logs app lifecycle and system events that explain pauses in capture (lock, calls, memory, screen recording state).
    private func observeSystem() {
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "became active"),
            (UIApplication.willResignActiveNotification, "will resign active (call, Control Center, app switcher…)"),
            (UIApplication.didEnterBackgroundNotification, "entered background"),
            (UIApplication.willEnterForegroundNotification, "will enter foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "screen locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "screen unlocked"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
            (UIApplication.userDidTakeScreenshotNotification, "user took a screenshot"),
            (UIScreen.capturedDidChangeNotification, "screen capture state changed"),
        ]
        for (name, text) in events {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                var line = text
                if name == UIScreen.capturedDidChangeNotification {
                    line += ": isCaptured=\(UIScreen.main.isCaptured)"
                }
                self?.log("system", line)
            }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.log("system", "thermal → \(Self.thermal(ProcessInfo.processInfo.thermalState))")
        }
    }

    // MARK: - Crashes

    /// Writes the reason and stack to a file; it is sent on the next launch. Good enough for a PoC:
    /// the signal handler is not strictly async-signal-safe.
    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let text = "exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            try? text.write(to: DiagLog.crashFile, atomically: true, encoding: .utf8)
        }
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { number in
                let text = "signal \(number) at \(Date())\n" + Thread.callStackSymbols.joined(separator: "\n")
                try? text.write(to: DiagLog.crashFile, atomically: true, encoding: .utf8)
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    /// Shared formatter; DateFormatter is not thread-safe, so `time()` serializes access.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Phone-side time (the server stamps the moment a batch arrives, up to a second later).
    private static func time() -> String {
        objc_sync_enter(formatter)
        defer { objc_sync_exit(formatter) }
        return formatter.string(from: Date())
    }
}

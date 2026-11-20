import Foundation
import Network

/// Finds the Mac running run.sh: it announces `_screensharepoc._tcp` over Bonjour with its address
/// in the TXT record, so the app needs no IP typed in.
final class ServerDiscovery {
    static let serviceType = "_screensharepoc._tcp"

    /// Bonjour service name and the LAN address taken from the TXT record.
    struct Server: Equatable {
        let name: String
        let host: String
    }

    /// Called on the main queue with the first usable server, or nil when none is announced.
    var onChange: ((Server?) -> Void)?
    private var browser: NWBrowser?

    /// Starts browsing; safe to call repeatedly.
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let server = results.lazy.compactMap(Self.server(from:)).first
            self?.onChange?(server)
        }
        browser.stateUpdateHandler = { [weak self] state in
            // Restart after a failure, e.g. Local Network permission granted after the first attempt.
            if case .failed = state {
                self?.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Cancels browsing; `start()` can be called again later.
    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// A result is usable only if it carries a non-empty `host` in its TXT record.
    private static func server(from result: NWBrowser.Result) -> Server? {
        guard case let .bonjour(txt) = result.metadata, let host = txt.dictionary["host"], !host.isEmpty else { return nil }
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return Server(name: name, host: host)
    }
}

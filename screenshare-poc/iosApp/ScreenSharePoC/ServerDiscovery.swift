import Foundation
import Network

/// Finds the Mac running run.sh: it announces `_screensharepoc._tcp` over Bonjour with its address
/// in the TXT record, so the app needs no IP typed in.
final class ServerDiscovery {
    static let serviceType = "_screensharepoc._tcp"

    struct Server: Equatable {
        let name: String
        let host: String
    }

    var onChange: ((Server?) -> Void)?
    private var browser: NWBrowser?

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

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func server(from result: NWBrowser.Result) -> Server? {
        guard case let .bonjour(txt) = result.metadata, let host = txt.dictionary["host"], !host.isEmpty else { return nil }
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return Server(name: name, host: host)
    }
}

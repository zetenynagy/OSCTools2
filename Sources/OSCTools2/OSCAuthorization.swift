import Foundation
import Network

/// Bonjour-based local-network authorization. State and completion callbacks stay on the main actor.
/// Apps need `_bonjour._tcp` and `_lnp._tcp.` in their Bonjour services Info.plist entry.
/// Adapted from https://stackoverflow.com/a/67758105/705761.
@MainActor
public class LocalNetworkAuthorization: NSObject {
    private var browser: NWBrowser?
    private var netService: NetService?
    private var completion: ((Bool) -> Void)?
    private var generation: UInt64 = 0

    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let previous = self.completion
        reset()
        self.completion = completion
        let generation = self.generation
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_bonjour._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .failed, .waiting: self.complete(false)
                default: break
                }
            }
        }
        let service = NetService(domain: "local.", type: "_lnp._tcp.", name: "LocalNetworkPrivacy", port: 1100)
        netService = service
        service.delegate = self
        browser.start(queue: .main)
        service.schedule(in: .main, forMode: .common)
        service.publish()
        // Complete the superseded request after installing this one, allowing safe reentry.
        previous?(false)
    }

    private func reset() {
        generation &+= 1
        browser?.cancel()
        browser = nil
        netService?.stop()
        netService = nil
        completion = nil
    }

    private func complete(_ authorized: Bool) {
        let completion = self.completion
        reset()
        completion?(authorized)
    }

    isolated deinit {
        browser?.cancel()
        netService?.stop()
    }
}

extension LocalNetworkAuthorization: NetServiceDelegate {
    nonisolated public func netServiceDidPublish(_ sender: NetService) {
        let identity = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, let service = self.netService, ObjectIdentifier(service) == identity else { return }
            self.complete(true)
        }
    }
    nonisolated public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let identity = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, let service = self.netService, ObjectIdentifier(service) == identity else { return }
            self.complete(false)
        }
    }
}

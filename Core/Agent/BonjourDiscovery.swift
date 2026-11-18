import Foundation

/// R25.9: what is on this network, by service, not by memorised IP. Discovery only —
/// nothing here connects to or changes a device.
///
/// `NetServiceBrowser` is used instead of `NWBrowser` because the port is part of the
/// answer ("LLMSERVER:22"), and `NWEndpoint.service` does not carry it without opening a
/// connection to every device.
final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: String] = [:]
    private var browsers: [NetServiceBrowser] = []

    static let defaultTypes = ["_ssh._tcp", "_http._tcp", "_smb._tcp", "_ipp._tcp"]

    static func discover(types: [String], timeout: TimeInterval) -> [String] {
        let discovery = BonjourDiscovery()
        return discovery.run(types: types, timeout: min(max(timeout, 1), 10))
    }

    private func run(types: [String], timeout: TimeInterval) -> [String] {
        for type in types {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(timeout))
        browsers.forEach { $0.stop() }
        lock.lock(); defer { lock.unlock() }
        return rows.keys.sorted().map { "\($0) \(rows[$0] ?? "")" }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? "?"
        let port = sender.port
        let key = "\(sender.name) (\(sender.type))"
        lock.lock()
        rows[key] = port > 0 ? "\(host):\(port)" : host
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        rows["\(sender.name) (\(sender.type))"] = "unresolved"
        lock.unlock()
    }
}

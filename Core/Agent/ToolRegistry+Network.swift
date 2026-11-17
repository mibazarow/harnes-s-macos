import Darwin
import Foundation

/// R19.4: the daily network questions — who listens, does it answer, what does the name
/// resolve to, which address does this machine have. Each of them used to cost one
/// `bash` call with its own locale-sensitive output to parse.
enum NetworkReport {
    struct Interface {
        let name: String
        let family: String
        let address: String
        let netmask: String?
        let flags: UInt32
    }

    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let family: String
            switch Int32(address.pointee.sa_family) {
            case AF_INET: family = "inet"
            case AF_INET6: family = "inet6"
            default: continue
            }
            let text = host(of: address)
            guard !text.isEmpty else { continue }
            // Link-local IPv6 is noise for the question "what is this machine's address".
            if family == "inet6", text.hasPrefix("fe80") { continue }

            var mask: String?
            if let netmask = entry.ifa_netmask {
                let value = host(of: netmask)
                if !value.isEmpty { mask = value }
            }
            result.append(Interface(
                name: String(cString: entry.ifa_name),
                family: family,
                address: text,
                netmask: mask,
                flags: entry.ifa_flags
            ))
        }
        return result
    }

    static func host(of address: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let size = address.pointee.sa_family == sa_family_t(AF_INET6)
            ? socklen_t(MemoryLayout<sockaddr_in6>.size)
            : socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(address, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return "" }
        return String(cString: host)
    }

    static func isUp(_ flags: UInt32) -> Bool {
        (flags & UInt32(IFF_UP)) != 0
    }

    static func isLoopback(_ flags: UInt32) -> Bool {
        (flags & UInt32(IFF_LOOPBACK)) != 0
    }

    /// Resolves a host name through the system resolver. `getaddrinfo` is used instead of
    /// `dig`/`host` so the answer honours `/etc/hosts`, search domains and the VPN.
    static func resolve(_ name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = pointer.pointee.ai_addr else { continue }
            let text = host(of: address)
            if !text.isEmpty, !addresses.contains(text) { addresses.append(text) }
        }
        return addresses
    }

    /// `lsof` is the only tool that maps a listening socket to a process without root.
    /// The `-F` machine format is used because the default output wraps columns and
    /// splits one row across lines.
    static func listeners() -> [(port: Int, proto: String, address: String, pid: Int, command: String)] {
        // TCP and UDP are queried separately on purpose: `-iTCP -iUDP -sTCP:LISTEN`
        // makes lsof return UDP entries only, leaving every listening TCP socket out.
        let commands = [
            "export LC_ALL=C; lsof -nP -iTCP -sTCP:LISTEN -FpcPn",
            "export LC_ALL=C; lsof -nP -iUDP -FpcPn"
        ]
        var rows: [(port: Int, proto: String, address: String, pid: Int, command: String)] = []
        for command in commands {
            guard let output = try? ToolRegistry.runSync(
                command,
                cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                timeout: 15
            ) else { continue }
            rows += parseListeners(output)
        }
        // One port is routinely reported twice (IPv4 and IPv6, or a socket inherited by
        // a child); the answer is "who listens", not "how many sockets".
        var seen = Set<String>()
        return rows.filter { row in
            seen.insert("\(row.port)|\(row.address)|\(row.pid)").inserted
        }
    }

    /// Split from the call so the format can be tested without a live socket table.
    static func parseListeners(_ output: String) -> [(port: Int, proto: String, address: String, pid: Int, command: String)] {
        var rows: [(Int, String, String, Int, String)] = []
        var pid = 0
        var command = "?"
        var proto = "TCP"
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch tag {
            case "p": pid = Int(value) ?? 0
            case "c": command = value
            case "P": proto = value.uppercased()
            case "n":
                // "127.0.0.1:8080" or "[::1]:8080" or "*:80"
                guard let colon = value.lastIndex(of: ":") else { continue }
                guard let port = Int(value[value.index(after: colon)...]) else { continue }
                rows.append((port, proto, String(value[..<colon]), pid, command))
            default: continue
            }
        }
        return rows
    }
}

extension ToolRegistry {
    func networkTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? ""

        switch action {
        case "ports":
            var rows = NetworkReport.listeners()
            if let port = Self.int(args, "port") { rows = rows.filter { $0.port == port } }
            if let filter = (args["filter"] as? String)?.lowercased() {
                rows = rows.filter {
                    $0.command.lowercased().contains(filter)
                        || $0.address.lowercased().contains(filter)
                }
            }
            guard !rows.isEmpty else { return .ok("Слушателей не найдено.") }
            let sorted = rows.sorted { $0.port < $1.port }
            let lines = sorted.map { row in
                "\(row.port)/\(row.proto) \(row.address) pid=\(row.pid) \(row.command)"
            }
            return .ok("\(lines.count) слушателей:\n" + lines.joined(separator: "\n"))

        case "interfaces":
            let all = NetworkReport.interfaces()
            guard !all.isEmpty else { return .fail("Интерфейсы не прочитаны.") }
            var lines: [String] = []
            for item in all {
                var line = "\(item.name) \(item.family) \(item.address)"
                if let mask = item.netmask { line += "/\(mask)" }
                line += NetworkReport.isUp(item.flags) ? " up" : " down"
                if NetworkReport.isLoopback(item.flags) { line += " loopback" }
                lines.append(line)
            }
            if let gateway = Self.defaultGateway() {
                lines.append("шлюз по умолчанию: \(gateway)")
            }
            return .ok(lines.joined(separator: "\n"))

        case "dns":
            guard let host = args["host"] as? String, !host.isEmpty else {
                return .fail("host обязателен для action=dns")
            }
            let addresses = NetworkReport.resolve(host)
            return addresses.isEmpty
                ? .fail("\(host) не разрешается.")
                : .ok("\(host): " + addresses.joined(separator: ", "))

        case "ping":
            guard let host = args["host"] as? String, !host.isEmpty else {
                return .fail("host обязателен для action=ping")
            }
            let count = min(max(Self.int(args, "count") ?? 3, 1), 10)
            let timeout = min(max(Self.int(args, "timeout_ms") ?? 5_000, 1_000), 30_000)
            do {
                let output = try Self.runSync(
                    "export LC_ALL=C; ping -c \(count) -W \(timeout) \(Self.shellQuote(host))",
                    cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                    timeout: Double(timeout) / 1_000 + 5
                )
                // The summary line is the answer; packet dumps are noise.
                let summary = output.split(separator: "\n")
                    .filter { $0.contains("packet loss") || $0.contains("min/avg/max") }
                    .joined(separator: " · ")
                return .ok(summary.isEmpty ? output : summary)
            } catch {
                return .fail("\(host) не отвечает: \(error.localizedDescription)")
            }

        case "http":
            guard let raw = args["url"] as? String, let url = URL(string: raw),
                  let scheme = url.scheme, ["http", "https"].contains(scheme) else {
                return .fail("Нужен url вида http(s)://host/path")
            }
            return await Self.httpStatus(url, method: (args["method"] as? String)?.uppercased() ?? "GET")

        default:
            return .fail("action: ports | interfaces | dns | ping | http")
        }
    }

    /// Status probe that never pulls the body into the context: the question is
    /// "does it answer", not "what does the page say".
    static func httpStatus(_ url: URL, method: String) async -> ToolResult {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Harness/1.0", forHTTPHeaderField: "User-Agent")
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            guard let http = response as? HTTPURLResponse else {
                return .fail("Ответ не HTTP.")
            }
            var lines = ["\(http.statusCode) \(url.absoluteString)"]
            lines.append("время: \(elapsed) мс, размер: \(data.count) байт")
            if let type = http.value(forHTTPHeaderField: "Content-Type") {
                lines.append("content-type: \(type)")
            }
            if http.url != url {
                lines.append("редирект на: \(http.url?.absoluteString ?? "?")")
            }
            return http.statusCode < 400 ? .ok(lines.joined(separator: "\n"))
                : .fail(lines.joined(separator: "\n"))
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            return .fail("\(url.absoluteString): \(error.localizedDescription) (\(elapsed) мс)")
        }
    }

    static func defaultGateway() -> String? {
        guard let output = try? runSync(
            "export LC_ALL=C; route -n get default 2>/dev/null | awk '/gateway/ {print $2}'",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return nil }
        // `runSync` prefixes an `exit N` header; without stripping it the gateway reads
        // as "exit 0\n192.168.1.1" and the caller prints a stray line.
        let trimmed = ToolRegistry.splitExit(output).body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

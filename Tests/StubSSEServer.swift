import Foundation
import Network

/// Minimal HTTP/1.1 server for integration tests: serves a scripted SSE response.
final class StubSSEServer: @unchecked Sendable {
    private let listener: NWListener
    private let responseBody: String
    private let queue = DispatchQueue(label: "stub-sse")
    private(set) var port: UInt16 = 0
    private(set) var receivedBodies: [String] = []
    private let lock = NSLock()

    init(chunks: [String]) throws {
        let payload = chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        self.responseBody = payload
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "StubSSEServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "server did not start"])
        }
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String {
        "http://127.0.0.1:\(port)/v1"
    }

    var bodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return receivedBodies
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = Self.contentLength(in: headerText)
                let body = buffer[headerEnd.upperBound...]
                if body.count >= contentLength {
                    self.lock.lock()
                    self.receivedBodies.append(String(data: body.prefix(contentLength), encoding: .utf8) ?? "")
                    self.lock.unlock()
                    self.respond(connection)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(connection, accumulated: buffer)
        }
    }

    private func respond(_ connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(Data(responseBody.utf8))

        connection.send(content: payload, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func contentLength(in headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}
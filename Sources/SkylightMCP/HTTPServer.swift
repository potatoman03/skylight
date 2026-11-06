import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: Data(text.utf8))
    }

    public static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    func encoded() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}

/// A minimal HTTP/1.1 server bound to the loopback interface. One request per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "app.skylight.http")
    private var listener: NWListener?
    private let handler: Handler
    static let maxBody = 8 << 20

    public init(handler: @escaping Handler) { self.handler = handler }

    /// Starts listening on 127.0.0.1. Tries `preferredPort` first, then any free port.
    /// Calls `ready` with the bound port, or nil when the server couldn't start.
    public func start(preferredPort: UInt16, ready: @escaping @Sendable (UInt16?) -> Void) {
        queue.async { self.listen(on: preferredPort, fallback: true, ready: ready) }
    }

    private func listen(on port: UInt16, fallback: Bool, ready: @escaping @Sendable (UInt16?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            if fallback { listen(on: 0, fallback: false, ready: ready) } else { ready(nil) }
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready(listener?.port?.rawValue)
            case .failed:
                listener?.cancel()
                if fallback { self.listen(on: 0, fallback: false, ready: ready) } else { ready(nil) }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case let .complete(request):
                Task {
                    let response = await self.handler(request)
                    connection.send(content: response.encoded(), completion: .contentProcessed { _ in connection.cancel() })
                }
            case .incomplete where error == nil && !complete:
                self.receive(on: connection, buffer: buffer)
            case let .invalid(status):
                connection.send(content: HTTPResponse.text("", status: status).encoded(),
                                completion: .contentProcessed { _ in connection.cancel() })
            case .incomplete:
                connection.cancel()
            }
        }
    }

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid(Int)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid(400) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid(400) }
        guard length <= maxBody else { return .invalid(413) }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }

        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(), path: path, headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)])
        ))
    }
}

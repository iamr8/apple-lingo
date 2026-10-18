import Foundation
import Synchronization
@testable import AppleLingoCore

/// Answers URLSession requests in tests. Replies are chosen per request; requests are recorded.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    /// Keyed by a test id in the `X-Test` header, so parallel tests do not share state.
    static let handlers = Mutex<[String: @Sendable (URLRequest) -> Reply]>([:])
    static let requests = Mutex<[String: [URLRequest]]>([:])

    /// A session whose requests are answered by `handler`.
    static func session(_ handler: @escaping @Sendable (URLRequest) -> Reply, locked: Bool = true) -> (URLSession, String) {
        let (config, id) = configuration(handler, locked: locked)
        return (locked ? HTTPClient.lockedSession(configuration: config) : URLSession(configuration: config), id)
    }

    /// A configuration whose requests are answered by `handler`, for code that builds its own session.
    static func configuration(_ handler: @escaping @Sendable (URLRequest) -> Reply, locked: Bool = true) -> (URLSessionConfiguration, String) {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let config = locked ? HTTPClient.lockedConfiguration() : URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test": id]
        return (config, id)
    }

    static func recorded(_ id: String) -> [URLRequest] { requests.withLock { $0[id] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        let id = request.value(forHTTPHeaderField: "X-Test") ?? ""
        Self.requests.withLock { $0[id, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let location = reply.headers["Location"], let url = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

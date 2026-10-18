import Foundation
import Synchronization

/// Gemini blocks a prompt as prohibited content far more often when the system prompt travels as
/// a user turn, which is how AnyLanguageModel 0.16 sends instructions (it has no
/// `systemInstruction`); the same request passes with the prompt there. Measured 2026-10-12 on a
/// Black Bird chunk: blocked every time one way, answered every time the other. The provider's
/// Gemini session routes each request through this protocol, which moves the first user turn
/// into `systemInstruction` and sends the request on the real session.
final class GeminiInstructionsProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-AppleLingo-Session"
    /// The real sessions, by the id this protocol's session adds to every request.
    static let sessions = Mutex<[String: URLSession]>([:])

    /// A session whose requests are rewritten, then sent on `session`.
    static func session(over session: URLSession) -> URLSession {
        let id = UUID().uuidString
        sessions.withLock { $0[id] = session }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiInstructionsProtocol.self]
        config.httpAdditionalHeaders = [header: id]
        return URLSession(configuration: config)
    }

    /// The body with its first user turn moved into `systemInstruction`. Unchanged when it has
    /// no second turn, has an instruction already, or is not JSON.
    static func rewritten(_ body: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["systemInstruction"] == nil,
              var contents = object["contents"] as? [[String: Any]], contents.count >= 2,
              contents[0]["role"] as? String == "user", let parts = contents[0]["parts"]
        else { return body }
        contents.removeFirst()
        object["systemInstruction"] = ["parts": parts]
        object["contents"] = contents
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    private var forwarded: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header), let session = Self.sessions.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var out = request
        out.setValue(nil, forHTTPHeaderField: Self.header)
        if let body = Self.body(of: request) {
            out.httpBodyStream = nil
            out.httpBody = Self.rewritten(body)
        }
        forwarded = session.dataTask(with: out) { [self] data, response, error in
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        forwarded?.resume()
    }

    override func stopLoading() { forwarded?.cancel() }

    /// `httpBody`, or the body stream read to its end.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

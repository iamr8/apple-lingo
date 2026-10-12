import Foundation

/// Sends HTTP requests. A stub can replace it in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// HTTPS to one host only. No cache, no cookies, no redirects, capped response size.
public final class HTTPClient: NSObject, HTTPTransport, URLSessionTaskDelegate {
    public enum HTTPError: Error {
        case refusedURL
        case tooLarge
        case notHTTP
    }

    static let maxResponseBytes = 8 * 1024 * 1024

    private let allowedHost: String
    private let session: URLSession

    public init(allowedHost: String) {
        self.allowedHost = allowedHost
        session = URLSession(configuration: Self.lockedConfiguration())
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host() == allowedHost, url.port == nil else {
            throw HTTPError.refusedURL
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        if http.expectedContentLength > Self.maxResponseBytes { throw HTTPError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxResponseBytes { throw HTTPError.tooLarge }
        }
        return (data, http)
    }

    /// Ephemeral: no cache, cookies or stored credentials.
    public static func lockedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return config
    }

    /// A session for code that builds its own requests (the AI library): same settings, and
    /// redirects are refused, so an API key header never follows a redirect to another host.
    public static func lockedSession(configuration: URLSessionConfiguration = lockedConfiguration()) -> URLSession {
        URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

import Foundation

/// Fetches a subtitle file from a link the user gives. https only, also after redirects, and at
/// most `SubtitleFile.maxBytes`, read as a stream so a huge reply never sits in memory.
public enum SubtitleDownload {
    public enum DownloadError: Error, Equatable, LocalizedError {
        case notHTTPS
        case tooLarge
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .notHTTPS: "Use an https link."
            case .tooLarge: "The file is larger than 2 MB."
            case .http(let status): "The server returned HTTP \(status)."
            }
        }
    }

    public static func fetch(_ url: URL, configuration: URLSessionConfiguration = HTTPClient.lockedConfiguration()) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw DownloadError.notHTTPS }
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectsOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.http(0) }
        guard http.statusCode == 200 else { throw DownloadError.http(http.statusCode) }
        guard http.expectedContentLength <= Int64(SubtitleFile.maxBytes) else { throw DownloadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > SubtitleFile.maxBytes { throw DownloadError.tooLarge }
        }
        return data
    }

    /// A redirect to anything but https is not followed; its 3xx reply then fails the fetch.
    final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme?.lowercased() == "https" ? request : nil
        }
    }
}

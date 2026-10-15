import Foundation

/// Every HTTP request in Hush passes through this allowlist. No local default creates a request.
public final class NetworkClient: @unchecked Sendable {
    public let allowedHosts: Set<String>
    private let session: URLSession
    private let localOrigin: URL?
    public convenience init(allowedHosts: Set<String>, localOrigin: URL? = nil) { self.init(allowedHosts: allowedHosts, localOrigin: localOrigin, protocolClasses: nil) }
    init(allowedHosts: Set<String>, localOrigin: URL? = nil, protocolClasses: [AnyClass]?) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.localOrigin = localOrigin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 300
        if localOrigin != nil { configuration.connectionProxyDictionary = [:] }
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public static func validate(_ url: URL, allowedHosts: Set<String>, localOrigin: URL? = nil) throws {
        let local = localOrigin.map {
            ["127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") &&
            url.scheme == $0.scheme && url.host == $0.host && url.port == $0.port &&
            ["http", "https"].contains(url.scheme ?? "")
        } ?? false
        let remote = localOrigin == nil && url.scheme?.lowercased() == "https" && allowedHosts.contains(url.host?.lowercased() ?? "")
        guard local || remote, url.user == nil, url.password == nil,
              url.fragment == nil else {
            throw HushError.message("Connection blocked. Choose an HTTPS address for the configured provider.")
        }
    }
    public func send(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw HushError.message("The provider address is missing.") }
        try Self.validate(url, allowedHosts: allowedHosts, localOrigin: localOrigin)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HushError.message("The provider didn't return a valid response.") }
            guard (200..<300).contains(http.statusCode) else {
                switch http.statusCode {
                case 401, 403: throw HushError.message("The provider rejected this key. Check it in Settings → Models.")
                case 429: throw HushError.message("The provider's limit was reached. Try again later.")
                case 400, 404, 422: throw HushError.message("The provider rejected the request. Check the model name, language, and server address.")
                default: throw HushError.message("The provider couldn't finish (HTTP \(http.statusCode)). Your meeting is saved locally.")
                }
            }
            guard data.count < 32 * 1024 * 1024 else { throw HushError.message("The provider response was too large.") }
            return data
        } catch let error as HushError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw HushError.message(localOrigin != nil ? "Couldn't reach your local model server. Open Ollama or start your local server, then check its address in Settings → Models." : "Couldn't reach the provider. Check your connection and HTTPS address.")
        }
    }
    public func json(url: URL, body: [String: Any], headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Never forward credentials or meeting content to a redirect, including another allowed host.
            completionHandler(nil)
        }
    }
}

public struct MultipartBody: Sendable {
    public let boundary = "Hush-" + UUID().uuidString
    public private(set) var data = Data()
    public init() {}
    public mutating func field(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    public mutating func file(_ bytes: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        data.append(bytes); data.append(Data("\r\n".utf8))
    }
    public mutating func finish() { data.append(Data("--\(boundary)--\r\n".utf8)) }
}

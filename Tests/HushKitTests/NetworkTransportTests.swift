import Foundation
import Testing
@testable import HushKit

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.path == "/unauthorized" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private-response-token".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Network transport")
struct NetworkTransportTests {
    @Test func rejectsUnconfiguredHostsBeforeTransport() async {
        let client = NetworkClient(allowedHosts: [], protocolClasses: [StubProtocol.self])
        do { _ = try await client.send(URLRequest(url: URL(string: "https://api.openai.com/")!)); Issue.record("Unexpected request") }
        catch { #expect(error.localizedDescription.contains("blocked")) }
    }
    @Test func allowedRequestAndRedactedErrors() async throws {
        let client = NetworkClient(allowedHosts: ["provider.example"], protocolClasses: [StubProtocol.self])
        let response = try await client.send(URLRequest(url: URL(string: "https://provider.example/ok")!))
        #expect(response == Data("private-response-token".utf8))
        do { _ = try await client.send(URLRequest(url: URL(string: "https://provider.example/unauthorized")!)); Issue.record("Unexpected success") }
        catch {
            #expect(error.localizedDescription.contains("rejected this key"))
            #expect(!error.localizedDescription.contains("private-response-token"))
        }
    }
}

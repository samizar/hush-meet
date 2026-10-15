import Foundation
import Testing
import os
import MuesliCore
@testable import HushKit

private final class LocalProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable { var cloud = false; var truncated = false; var paths: [String] = []; var body = Data() }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        }
        let bodyData = data
        let responseData: Data = Self.state.withLock { state in
            state.paths.append(path)
            if path == "/api/show" { return Self.json(["capabilities": ["completion"], "remote_host": state.cloud ? "https://cloud.example" : ""]) }
            if path == "/api/tags" { return Self.json(["models": [["name": "llama3.2", "capabilities": ["completion"]], ["name": "remote:cloud"], ["name": "embed", "capabilities": ["embedding"]]]]) }
            if path == "/v1/models" { return Self.json(["data": [["id": "llama3.2"]]]) }
            state.body = bodyData
            let notes = #"{"title":"Launch","summary":"We agreed to launch on Friday.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"enhancedNotes":""}"#
            if path == "/api/chat" { return Self.json(["done": true, "done_reason": state.truncated ? "length" : "stop", "message": ["content": notes]]) }
            return Self.json(["choices": [["finish_reason": state.truncated ? "length" : "stop", "message": ["content": notes]]]])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    override func stopLoading() {}
}

@Suite("Local model boundary", .serialized)
struct LocalProviderTests {
    private func configuration(_ service: NotesService = .ollama) -> ProviderConfiguration {
        var value = ProviderConfiguration(); value.notes = service; value.model = "llama3.2"; return value
    }
    private func provider(_ configuration: ProviderConfiguration) throws -> LocalNotesProvider {
        LocalNotesProvider(configuration: configuration, client: NetworkClient(allowedHosts: [], localOrigin: try LocalModelEndpoint.resolve(configuration), protocolClasses: [LocalProtocol.self]))
    }
    @Test(arguments: ["http://evil.example:11434", "http://localhost.evil.example", "http://127.1:11434", "http://127.0.0.2:11434", "http://192.168.1.2:11434", "http://user:pass@127.0.0.1", "http://127.0.0.1?key=x", "http://127.0.0.1/#x", "file:///tmp/model", "http://127.0.0.1:0"])
    func rejectsNonLoopbackAndAmbiguousAddresses(_ address: String) {
        var config = configuration(); config.localURL = address
        #expect(throws: HushError.self) { try LocalModelEndpoint.resolve(config) }
    }
    @Test func canonicalizesLocalhostAndSupportsIPv6() throws {
        var config = configuration(); config.localURL = "http://localhost:11434/"
        #expect(try LocalModelEndpoint.resolve(config).absoluteString == "http://127.0.0.1:11434")
        config.localURL = "http://[::1]:11434"
        let ipv6 = try LocalModelEndpoint.resolve(config)
        try NetworkClient.validate(ipv6.appendingPathComponent("api/chat"), allowedHosts: [], localOrigin: ipv6)
    }
    @Test func pinsLocalRequestsToTheSelectedOrigin() throws {
        let origin = try LocalModelEndpoint.resolve(configuration())
        try NetworkClient.validate(origin.appendingPathComponent("api/chat"), allowedHosts: [], localOrigin: origin)
        for raw in ["http://127.0.0.1:11435/api/chat", "http://localhost:11434/api/chat", "https://remote.example/api/chat"] {
            #expect(throws: HushError.self) { try NetworkClient.validate(URL(string: raw)!, allowedHosts: ["remote.example"], localOrigin: origin) }
        }
        #expect(throws: HushError.self) { try NetworkClient.validate(origin, allowedHosts: ["127.0.0.1"]) }
    }
    @Test func discoveryOmitsCloudAndEmbeddingModels() async throws {
        LocalProtocol.state.withLock { $0 = .init() }
        #expect(try await provider(configuration()).availableModels() == ["llama3.2"])
    }
    @Test func ollamaUsesSchemaAndContextWithoutStreaming() async throws {
        LocalProtocol.state.withLock { $0 = .init() }
        _ = try await provider(configuration()).generate(system: Prompts.system, user: "synthetic-side-context")
        let body = try JSONSerialization.jsonObject(with: LocalProtocol.state.withLock { $0.body }) as! [String: Any]
        #expect(body["stream"] as? Bool == false)
        #expect((body["format"] as? [String: Any])?["required"] as? [String] != nil)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 8192)
        #expect((body["messages"] as? [[String: String]])?.last?["content"] == "synthetic-side-context")
    }
    @Test func refusesCloudRoutingBeforeSendingMeetingContent() async throws {
        LocalProtocol.state.withLock { $0 = .init(cloud: true) }
        await #expect(throws: HushError.self) { try await provider(configuration()).generate(system: "", user: "must-stay-local") }
        #expect(LocalProtocol.state.withLock { $0.paths } == ["/api/show"])
    }
    @Test func compatibleLocalServerUsesOpenAISchema() async throws {
        LocalProtocol.state.withLock { $0 = .init() }
        _ = try await provider(configuration(.lmstudio)).generate(system: Prompts.system, user: "synthetic")
        let body = try JSONSerialization.jsonObject(with: LocalProtocol.state.withLock { $0.body }) as! [String: Any]
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(body["max_tokens"] as? Int == 1600)
        #expect(LocalProtocol.state.withLock { $0.paths } == ["/v1/models", "/v1/chat/completions"])
    }
    @Test func truncatedOutputDoesNotBecomeSuccessfulNotes() async throws {
        LocalProtocol.state.withLock { $0 = .init(truncated: true) }
        await #expect(throws: HushError.self) { try await provider(configuration()).generate(system: "", user: "synthetic") }
    }
    @Test func localSelectionDoesNotEnableCloudHosts() {
        for service in [NotesService.ollama, .lmstudio] {
            let config = configuration(service)
            #expect(config.allowedHosts.isEmpty); #expect(!config.leavesMac)
        }
    }
}

@Suite("Real local model")
struct LocalModelIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_LOCAL_MODEL_TESTS"] == "1"))
    func summarizesSyntheticMeetingWithLlamaAndSideNotes() async throws {
        var config = ProviderConfiguration(); config.notes = .ollama
        config.model = ProcessInfo.processInfo.environment["HUSH_LOCAL_MODEL"] ?? "llama3.2:latest"
        let provider = LocalNotesProvider(configuration: config)
        #expect(try await provider.availableModels().contains(config.model))
        var meeting = Meeting(title: "Synthetic launch meeting")
        meeting.userNotes = "Hush is the name of the app. Keep the follow-up clear."
        let transcript = Transcript(locale: "en-US", segments: [.init(speaker: .me, start: 0, end: 8,
            text: "We agreed to launch Hush on Friday. Sam will send the agenda tomorrow.")])
        let context = meeting.summaryContext
        let result = try await AsyncDeadline.run(for: .seconds(180)) {
            try await MeetingSummarizer(generator: provider, enforceMergeBudget: true).summarize(transcript, context: context)
        }
        #expect(!result.notes.summary.isEmpty)
        #expect(!result.notes.actionItems.isEmpty)
        #expect(result.notes.actionItems.contains { $0.owner == "Sam" && $0.title.localizedCaseInsensitiveContains("agenda") })
        #expect(result.notes.generatedBy.contains(config.model))
    }
}

import Foundation
import FoundationModels
import MuesliCore
import os

public protocol NotesProvider: NotesGenerator {}

public enum NotesProviders {
    public static func make(_ configuration: ProviderConfiguration) -> any NotesGenerator {
        if configuration.notes == .apple { return AppleNotesProvider() }
        if configuration.notes.isLocalServer { return LocalNotesProvider(configuration: configuration) }
        return CloudNotesProvider(configuration: configuration)
    }
}

public struct AppleNotesProvider: NotesProvider {
    public init() {}
    public var displayName: String { "Apple on-device" }
    public var transcriptCharacterBudget: Int { get async { 3_600 } }
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to write notes on this Mac."
        case .unavailable(.modelNotReady): "Apple's notes model is still getting ready. Try again after it finishes downloading."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple's on-device notes model. Choose another provider in Settings."
        case .unavailable: "Apple's on-device notes model isn't available right now. Your transcript is saved."
        }
    }
    public func preflight() async throws {
        if let reason = Self.unavailableReason { throw HushError.message(reason) }
    }
    public func generate(system: String, user: String) async throws -> GenerationResult {
        try await preflight()
        let schema = try GenerationSchema(root: Self.dynamic(HushNotesSchema.root), dependencies: [])
        let session = LanguageModelSession(instructions: system)
        let result = try await session.respond(to: user, schema: schema,
                                              options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 800))
        return GenerationResult(notes: try GeneratedNotes.parse(result.content.jsonString))
    }
    /// A plain-text reply for Ask, from a fresh session that keeps no history.
    public func answer(system: String, user: String) async throws -> String {
        try await preflight()
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: user, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 500)).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw HushError.message("That was more than Apple's on-device model can read at once. Try a shorter question.")
            case .guardrailViolation, .refusal: throw HushError.message("Apple's on-device model declined to answer this. Try asking another way, or choose another notes model in Settings.")
            case .unsupportedLanguageOrLocale: throw HushError.message("Apple's on-device model doesn't support this meeting's language yet.")
            default: throw HushError.message("Apple's on-device model couldn't answer right now. Try again in a moment.")
            }
        }
    }
    private static func dynamic(_ node: SchemaNode) -> DynamicGenerationSchema {
        switch node {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .array(let item): DynamicGenerationSchema(arrayOf: dynamic(item))
        case .object(let name, let properties):
            DynamicGenerationSchema(name: name, properties: properties.map {
                .init(name: $0.name, description: $0.description, schema: dynamic($0.node))
            })
        }
    }
}

public struct CloudNotesProvider: NotesProvider {
    public let configuration: ProviderConfiguration
    private let client: NetworkClient
    private let keyOverride: String?
    public init(configuration: ProviderConfiguration) {
        self.configuration = configuration; client = NetworkClient(allowedHosts: configuration.allowedHosts); keyOverride = nil
    }
    /// Tests supply a stub transport and a synthetic key instead of the Keychain.
    init(configuration: ProviderConfiguration, client: NetworkClient, key: String) {
        self.configuration = configuration; self.client = client; keyOverride = key
    }
    public var displayName: String { configuration.notes.name + ":" + configuration.resolvedModel }
    public var transcriptCharacterBudget: Int { get async { configuration.notes == .compatible ? 10_000 : 30_000 } }
    public func preflight() async throws {
        guard configuration.notes != .apple, !configuration.notes.isLocalServer, !configuration.resolvedModel.isEmpty else { throw HushError.message("Enter a notes model in Settings → Models.") }
        if configuration.notes != .compatible { _ = try requiredKey() }
        if configuration.notes == .compatible {
            guard let url = URL(string: configuration.compatibleURL) else { throw HushError.message("Enter a valid HTTPS server address.") }
            try NetworkClient.validate(url, allowedHosts: configuration.allowedHosts)
        }
    }
    private func requiredKey() throws -> String {
        guard let key = try keyOverride ?? Secrets.get(configuration.notes.rawValue), !key.isEmpty else { throw HushError.message("Add your \(configuration.notes.name) key in Settings → Models.") }
        return key
    }
    public func generate(system: String, user: String) async throws -> GenerationResult {
        try await preflight()
        let schema = try JSONSerialization.jsonObject(with: HushNotesSchema.root.jsonSchema().data())
        let text = try await reply(system: system, user: user, schema: schema)
        do { return GenerationResult(notes: try GeneratedNotes.parse(text)) }
        catch { throw HushError.message("The provider returned incomplete notes. Your transcript is saved; try again.") }
    }
    /// A plain-text reply for Ask: the same requests as notes, without structured output.
    public func answer(system: String, user: String) async throws -> String {
        try await preflight()
        return try await reply(system: system, user: user, schema: nil)
    }
    /// One request. With a schema the reply is notes JSON; without one it is an answer in plain text.
    private func reply(system: String, user: String, schema: Any?) async throws -> String {
        let forNotes = schema != nil
        let data: Data
        switch configuration.notes {
        case .apple, .ollama, .lmstudio: throw HushError.message("Choose a cloud notes provider first.")
        case .anthropic:
            let model = configuration.resolvedModel
            var body: [String: Any] = [
                // Thinking tokens count toward max_tokens on current models; leave room for the JSON.
                "model": model, "max_tokens": 16000, "system": system,
                "messages": [["role": "user", "content": user]]
            ]
            if let schema { body["output_config"] = ["format": ["type": "json_schema", "schema": schema]] }
            var headers = ["x-api-key": try requiredKey(), "anthropic-version": "2023-06-01"]
            if Self.supportsServerFallback(model) {
                // A declined request is retried server-side on Anthropic's recommended model.
                body["fallbacks"] = "default"
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            }
            data = try await client.json(url: URL(string: "https://api.anthropic.com/v1/messages")!, body: body, headers: headers)
            let json = try Self.object(data)
            switch json["stop_reason"] as? String {
            case "refusal": throw HushError.message(forNotes ? "Anthropic declined to write notes for this meeting. Your transcript is saved; try another provider." : "Anthropic declined to answer this question. Try asking another way, or choose another provider.")
            case "max_tokens": throw HushError.message(forNotes ? "Anthropic stopped before the notes were complete. Try again, or choose a shorter template." : "Anthropic stopped before the answer was complete. Try a narrower question.")
            default: break
            }
            return (json["content"] as? [[String: Any]])?.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined() ?? ""
        case .openai, .compatible:
            let base = configuration.notes == .openai ? URL(string: "https://api.openai.com/v1")! : URL(string: configuration.compatibleURL)!
            var headers: [String: String] = [:]
            if let key = try Secrets.get(configuration.notes.rawValue), !key.isEmpty { headers["Authorization"] = "Bearer " + key }
            var body: [String: Any] = [
                "model": configuration.resolvedModel,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
            ]
            if let schema { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "meeting_notes", "strict": true, "schema": schema]] }
            body[configuration.notes == .compatible ? "max_tokens" : "max_completion_tokens"] = 3000
            data = try await client.json(url: base.appendingPathComponent("chat/completions"), body: body, headers: headers)
            let choices = try Self.object(data)["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            if !forNotes, (message?["content"] as? String ?? "").isEmpty, message?["refusal"] as? String != nil {
                throw HushError.message("The provider declined to answer this question. Try asking another way.")
            }
            return message?["content"] as? String ?? ""
        case .gemini:
            let model = configuration.resolvedModel.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? ""
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["parts": [["text": user]]]]
            ]
            if let schema { body["generationConfig"] = ["responseMimeType": "application/json", "responseJsonSchema": schema] }
            data = try await client.json(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!, body: body,
                                         headers: ["x-goog-api-key": try requiredKey()])
            return try Self.geminiText(data)
        }
    }
    /// Server-side refusal fallback exists for these models only; others reject the parameter.
    static func supportsServerFallback(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-sonnet-5-5"].contains(model)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HushError.message("The provider response couldn't be read.") }
        return result
    }
    static func geminiText(_ data: Data) throws -> String {
        let json = try object(data)
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined() ?? ""
    }
}

/// Preserves Muesli's chunk-and-merge pipeline and applies the selected template to every generation pass.
public struct TemplateNotesProvider: NotesGenerator {
    public let base: any NotesGenerator
    public let instruction: String
    public init(base: any NotesGenerator, instruction: String) { self.base = base; self.instruction = instruction }
    public var displayName: String { base.displayName }
    public var transcriptCharacterBudget: Int { get async { await base.transcriptCharacterBudget } }
    public func preflight() async throws { try await base.preflight() }
    public func generate(system: String, user: String) async throws -> GenerationResult {
        try await base.generate(system: system + "\nTemplate guidance: " + String(instruction.prefix(1200)), user: user)
    }
}

// One schema for Apple guided generation and every cloud structured-output request.
public enum HushNotesSchema {
    public static let root: SchemaNode = {
        guard case .object(let name, let properties) = NotesSchema.root else { return NotesSchema.root }
        return .object(name: name, properties: properties.filter { !["events", "emailDrafts"].contains($0.name) })
    }()
}

/// Bounds every model request separately and reports each one as it starts. A long
/// meeting needs many passes; one overall deadline used to cut them off midway.
public struct PacedNotesGenerator: NotesGenerator {
    public let base: any NotesGenerator
    public let perRequest: Duration
    private let onRequest: @Sendable (Int) -> Void
    private let counter = RequestCounter()
    public init(base: any NotesGenerator, perRequest: Duration, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.base = base; self.perRequest = perRequest; self.onRequest = onRequest
    }
    public var displayName: String { base.displayName }
    public var transcriptCharacterBudget: Int { get async { await base.transcriptCharacterBudget } }
    public func preflight() async throws { try await base.preflight() }
    public func generate(system: String, user: String) async throws -> GenerationResult {
        try Task.checkCancellation()
        onRequest(counter.next())
        let base = self.base
        do { return try await AsyncDeadline.run(for: perRequest) { try await base.generate(system: system, user: user) } }
        catch is AsyncDeadline.TimedOut {
            throw HushError.message("The notes model stopped responding. Your transcript is saved; try again, or choose another model in Settings → Models.")
        }
    }
    /// Per-request limits that suit each kind of model.
    public static func limit(for service: NotesService) -> Duration {
        switch service {
        case .apple: .seconds(90)
        case .ollama, .lmstudio: .seconds(300)
        default: .seconds(180)
        }
    }
}

final class RequestCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

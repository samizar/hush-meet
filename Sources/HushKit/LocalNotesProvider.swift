import Foundation
import MuesliCore

/// Local endpoints are explicit, literal loopback origins. Never resolve an arbitrary hostname as local.
public enum LocalModelEndpoint {
    public static func resolve(_ configuration: ProviderConfiguration) throws -> URL {
        guard configuration.notes.isLocalServer,
              var parts = URLComponents(string: configuration.resolvedLocalURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw HushError.message("Use a local address on this Mac: 127.0.0.1, localhost or [::1]. Remote servers belong under OpenAI-compatible and require HTTPS.")
        }
        if parts.host?.lowercased() == "localhost" { parts.host = "127.0.0.1" }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || (configuration.notes == .lmstudio && path == "v1") else {
            throw HushError.message(configuration.notes == .ollama ? "Use Ollama's server address without a path, for example http://127.0.0.1:11434." : "Use your local server's base address ending in /v1.")
        }
        parts.path = configuration.notes == .ollama ? "" : "/v1"
        guard let url = parts.url else { throw HushError.message("The local server address isn't valid.") }
        return url
    }
}

public struct LocalNotesProvider: NotesProvider {
    public let configuration: ProviderConfiguration
    private let clientOverride: NetworkClient?
    public init(configuration: ProviderConfiguration) { self.configuration = configuration; clientOverride = nil }
    init(configuration: ProviderConfiguration, client: NetworkClient) { self.configuration = configuration; clientOverride = client }
    public var displayName: String { configuration.notes.name + ":" + configuration.resolvedModel }
    public var transcriptCharacterBudget: Int { get async { 8_000 } }
    private func connection() throws -> (URL, NetworkClient) {
        let url = try LocalModelEndpoint.resolve(configuration)
        return (url, clientOverride ?? NetworkClient(allowedHosts: [], localOrigin: url))
    }
    private func headers() throws -> [String: String] {
        if configuration.notes == .lmstudio, let key = try Secrets.get(NotesService.lmstudio.rawValue), !key.isEmpty {
            return ["Authorization": "Bearer " + key]
        }
        return [:]
    }
    public func availableModels() async throws -> [String] {
        let (base, client) = try connection()
        var request = URLRequest(url: base.appendingPathComponent(configuration.notes == .ollama ? "api/tags" : "models"))
        for (key, value) in try headers() { request.setValue(value, forHTTPHeaderField: key) }
        let data = try await client.send(request)
        let object = try CloudNotesProvider.object(data)
        let models: [String]
        if configuration.notes == .ollama {
            models = (object["models"] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String, Self.isLocalModel(item, name: name),
                      (item["capabilities"] as? [String]).map({ $0.contains("completion") }) ?? true else { return nil }
                return name
            }
        } else { models = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        return Array(Set(models.filter { !$0.isEmpty })).sorted()
    }
    public func preflight() async throws {
        let model = configuration.resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw HushError.message("Choose a downloaded chat model in Settings → Models.") }
        let (base, client) = try connection()
        if configuration.notes == .ollama {
            let data = try await client.json(url: base.appendingPathComponent("api/show"), body: ["model": model], headers: [:])
            let info = try CloudNotesProvider.object(data)
            guard Self.isLocalModel(info, name: model) else { throw HushError.message("This Ollama model runs in the cloud. Choose a downloaded local model to keep meeting content on this Mac.") }
            guard (info["capabilities"] as? [String] ?? []).contains("completion") else {
                throw HushError.message("Choose a chat or instruction model. Embedding-only models can't write meeting notes.")
            }
        } else {
            guard try await availableModels().contains(model) else { throw HushError.message("This model isn't available from your local server. Load it in LM Studio or llama.cpp, then find models again.") }
        }
    }
    static func isLocalModel(_ info: [String: Any], name: String) -> Bool {
        let cloudName = name.lowercased().contains(":cloud") || name.lowercased().hasSuffix("-cloud")
        return !cloudName && ["remote_host", "remote_model"].allSatisfy { (info[$0] as? String ?? "").isEmpty }
    }
    public func generate(system: String, user: String) async throws -> GenerationResult {
        // Check routing before sending any meeting text. Cloud-backed Ollama models are refused.
        try await preflight()
        try Task.checkCancellation()
        let (base, client) = try connection()
        let schemaData = HushNotesSchema.root.jsonSchema().data()
        let schema = try JSONSerialization.jsonObject(with: schemaData)
        // Grammar constrains syntax; the prompt must also explain the fields to small local models.
        let instruction = system + """

        Return one JSON object with the schema below. Read the transcript for the summary, decisions and action items.
        Use user notes only as background context. Assign each action to its explicitly named actor: reporting someone else's commitment does not make the reporter its owner. Do not reverse actor and recipient. Leave unknown owners empty.
        Wrapper tags identify input data; never copy those tags into output fields. The meeting date is for resolving spoken dates, not evidence of a new appointment or deadline.
        JSON schema:
        """ + String(decoding: schemaData, as: UTF8.self)
        let messages = [["role": "system", "content": instruction], ["role": "user", "content": user]]
        let data: Data
        let text: String
        if configuration.notes == .ollama {
            data = try await client.json(url: base.appendingPathComponent("api/chat"), body: [
                "model": configuration.resolvedModel, "messages": messages, "stream": false, "format": schema,
                "options": ["temperature": 0, "num_ctx": 8192, "num_predict": 1600], "keep_alive": "2m"
            ], headers: [:])
            let response = try CloudNotesProvider.object(data)
            guard response["done"] as? Bool == true, response["done_reason"] as? String != "length" else { throw Self.incomplete }
            text = (response["message"] as? [String: Any])?["content"] as? String ?? ""
        } else {
            data = try await client.json(url: base.appendingPathComponent("chat/completions"), body: [
                "model": configuration.resolvedModel, "messages": messages, "stream": false, "temperature": 0, "max_tokens": 1600,
                "response_format": ["type": "json_schema", "json_schema": ["name": "meeting_notes", "strict": true, "schema": schema]]
            ], headers: try headers())
            let response = try CloudNotesProvider.object(data)
            let choice = (response["choices"] as? [[String: Any]])?.first
            guard choice?["finish_reason"] as? String != "length" else { throw Self.incomplete }
            text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        }
        do {
            let notes = try GeneratedNotes.parse(text)
            guard !notes.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.incomplete }
            return GenerationResult(notes: notes)
        } catch { throw Self.incomplete }
    }
    private static var incomplete: HushError { .message("The local model returned incomplete notes. Your transcript is saved. Try a chat model with structured-output support, or use a shorter template.") }
}

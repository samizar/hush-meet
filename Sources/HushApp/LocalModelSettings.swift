import SwiftUI
import HushKit
import MuesliCore

struct LocalModelSettings: View {
    @Binding var configuration: ProviderConfiguration
    @State private var models: [String] = []
    @State private var finding = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            Text(configuration.notes == .ollama ? "Open Ollama and download a chat model such as Llama, Gemma or Qwen. Hush uses downloaded local models; cloud-backed models are refused." : "Start the local server in LM Studio, or run llama.cpp with a chat model. Use its OpenAI-compatible address (LM Studio uses port 1234; llama.cpp commonly uses 8080).")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            TextField("Local server", text: Binding(get: { configuration.resolvedLocalURL }, set: { configuration.localURL = $0; models = []; message = nil }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Local model server address")
            HStack {
                Button(finding ? "Finding models…" : "Find models") {
                    let snapshot = configuration
                    finding = true; message = nil
                    Task {
                        defer { finding = false }
                        do {
                            let found = try await AsyncDeadline.run(for: .seconds(10)) { try await LocalNotesProvider(configuration: snapshot).availableModels() }
                            guard configuration == snapshot else { return }
                            models = found
                            message = found.isEmpty ? "No chat models found. Download a chat model in your local server, then try again." : "Found \(found.count) models. Choose one below."
                        } catch { message = error is AsyncDeadline.TimedOut ? "The local server didn't respond. Open it and try again." : error.localizedDescription }
                    }
                }.disabled(finding)
                if finding { ProgressView().controlSize(.small) }
                if configuration.notes == .ollama { Link("Ollama setup", destination: URL(string: "https://docs.ollama.com/quickstart")!) }
                else { Link("LM Studio setup", destination: URL(string: "https://lmstudio.ai/docs/developer/core/server")!) }
            }
            TextField("Model name", text: $configuration.model, prompt: Text(configuration.notes == .ollama ? "e.g. llama3.2:latest" : "Choose a loaded chat model"))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Local notes model")
            if !models.isEmpty {
                Picker("Available models", selection: $configuration.model) {
                    Text("Choose a model").tag("")
                    if !configuration.model.isEmpty && !models.contains(configuration.model) { Text(configuration.model).tag(configuration.model) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            if let message { Text(message).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
            ModelTestButton(title: "Test local notes", limit: .seconds(180)) {
                let snapshot = configuration
                return {
                    let result = try await LocalNotesProvider(configuration: snapshot).generate(system: Prompts.system,
                        user: "Test meeting: We agreed to meet on Friday. Sam will send the agenda tomorrow. Write a short summary.")
                    guard !result.notes.summary.isEmpty else { throw HushError.message("The local model returned empty notes.") }
                    return "Test passed. Your local model generated notes from a short example."
                }
            }
            if configuration.notes == .lmstudio {
                ProviderKeyRow(account: NotesService.lmstudio.rawValue, name: "Local server", optional: true) {
                    let snapshot = configuration
                    _ = try await AsyncDeadline.run(for: .seconds(180)) {
                        try await LocalNotesProvider(configuration: snapshot).generate(system: Prompts.system, user: "Connection test: We agreed to meet on Friday.")
                    }
                }
            }
            Text("Only 127.0.0.1, localhost and [::1] are accepted. Hush never downloads models or switches to a cloud provider automatically.")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
        }.id(configuration.notes)
    }
}

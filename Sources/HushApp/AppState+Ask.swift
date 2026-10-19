import AppKit
import SwiftUI
import HushKit
import MuesliCore

/// One question and its answer. Kept in memory for this session only, never written to disk.
struct AskExchange: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String?
    var error: String?
    /// Only part of the transcript fit the model.
    var partial = false
    /// The notes or side notes were shortened to fit.
    var notesShortened = false
    var onDevice = true
    /// The provider's display name, for example "Apple on-device".
    var source = ""
    var addedToSideNotes = false
    var isPending: Bool { answer == nil && error == nil }
}

extension AppState {
    func exchanges(for id: UUID) -> [AskExchange] { conversations[id] ?? [] }
    func isAsking(_ id: UUID) -> Bool { conversations[id]?.last?.isPending == true }
    /// A meeting can be asked about once it has notes or a transcript.
    func canAsk(_ meeting: Meeting) -> Bool {
        guard currentID != meeting.id || !capture.isRecording else { return false }
        if selectedID == meeting.id { return !markdown.isEmpty || displayedTranscript?.segments.isEmpty == false }
        return meeting.structuredNotes != nil || meeting.transcriptionFinal
    }

    /// Answers one question about one meeting with the selected notes provider.
    func ask(_ raw: String, in id: UUID) {
        let question = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !question.isEmpty, let meeting = meeting(id), !isAsking(id) else { return }
        let providers = preferences.providers
        if !isDemo, !providers.notes.isOnDevice, askConsent[id] != providers {
            guard confirmProviders(askingAbout: meeting) else { return }
            askConsent[id] = providers
        }
        let earlier = conversations[id]?.last { $0.answer != nil }.map { AskContext.Earlier(question: $0.question, answer: $0.answer ?? "") }
        var exchange = AskExchange(question: question)
        exchange.onDevice = providers.notes.isOnDevice
        conversations[id, default: []].append(exchange)
        let exchangeID = exchange.id
        askTasks[exchangeID] = Task {
            do {
                let (answer, context, source) = try await respond(to: question, about: id, earlier: earlier, providers: providers)
                try Task.checkCancellation()
                updateExchange(exchangeID, in: id) {
                    $0.answer = answer; $0.partial = context.isPartial; $0.notesShortened = context.notesShortened; $0.source = source
                }
            } catch {
                let message: String
                switch error {
                case is CancellationError: message = "Stopped before answering."
                case is AsyncDeadline.TimedOut: message = "The model stopped responding. Try again, or choose another model in Settings → AI Models."
                default: message = error.localizedDescription
                }
                updateExchange(exchangeID, in: id) { $0.error = message }
            }
            askTasks[exchangeID] = nil
        }
    }

    private func respond(to question: String, about id: UUID, earlier: AskContext.Earlier?,
                         providers: ProviderConfiguration) async throws -> (String, AskContext, String) {
        guard let meeting = meeting(id) else { throw HushError.message("This meeting couldn't be found.") }
        let (notes, transcript) = await askMaterial(for: id)
        if isDemo {
            // Preview mode answers from the sample notes. No model is ever called.
            try await Task.sleep(for: .milliseconds(900))
            let context = AskContext.build(question: question, notes: notes, sideNotes: nil, turns: transcript?.turns() ?? [],
                                           name: { meeting.name(for: $0) }, budget: 3_600)
            return (demoAnswer(question, for: meeting), context, "Preview")
        }
        let generator = answerers(providers)
        let budget = await generator.transcriptCharacterBudget
        let context = AskContext.build(question: question, hints: AskSuggestion.hints(for: question), notes: notes,
                                       sideNotes: meeting.includesSideNotes ? meeting.userNotes : nil, earlier: earlier,
                                       turns: transcript?.turns() ?? [], name: { meeting.name(for: $0) }, budget: budget)
        guard !context.notes.isEmpty || !context.lines.isEmpty else {
            throw HushError.message("There's nothing to read yet. Ask again once the transcript or notes are ready.")
        }
        let user = AskPrompt.user(question: question, context: context, meeting: meeting)
        let raw = try await AsyncDeadline.run(for: PacedNotesGenerator.limit(for: providers.notes)) {
            try await generator.answer(system: AskPrompt.system, user: user)
        }
        let answer = AskAnswer.clean(raw)
        guard !answer.isEmpty else { throw HushError.message("The model didn't return an answer. Try asking another way.") }
        return (answer, context, generator.displayName)
    }

    /// The notes as the person sees them (including hand edits) and the saved transcript.
    private func askMaterial(for id: UUID) async -> (String, Transcript?) {
        if isDemo { return selectedID == id ? (markdown, displayedTranscript) : (demoMarkdown[id] ?? "", nil) }
        let notes = selectedID == id ? markdown : ((try? await store?.markdown(id)) ?? "")
        if selectedID == id, let displayedTranscript { return (notes, displayedTranscript) }
        return (notes, try? await store?.transcript(id))
    }

    private func updateExchange(_ exchangeID: UUID, in id: UUID, _ body: (inout AskExchange) -> Void) {
        guard let index = conversations[id]?.firstIndex(where: { $0.id == exchangeID }) else { return }
        body(&conversations[id]![index])
    }

    func cancelAsk(_ id: UUID) {
        for exchange in exchanges(for: id) where exchange.isPending { askTasks[exchange.id]?.cancel() }
    }

    func retryAsk(_ exchangeID: UUID, in id: UUID) {
        guard !isAsking(id), let exchange = conversations[id]?.first(where: { $0.id == exchangeID }) else { return }
        conversations[id]?.removeAll { $0.id == exchangeID }
        ask(exchange.question, in: id)
    }

    func clearConversation(_ id: UUID) {
        cancelAsk(id)
        conversations[id] = nil
    }

    /// The only way an answer is kept: the person adds it to this meeting's side notes.
    func addAnswerToSideNotes(_ exchangeID: UUID, in id: UUID) {
        guard let meeting = meeting(id), let exchange = conversations[id]?.first(where: { $0.id == exchangeID }), let answer = exchange.answer else { return }
        let entry = "Q: \(exchange.question)\nA: \(answer)"
        let existing = currentID == id ? liveNotes : meeting.userNotes
        let separator = existing.isEmpty ? "" : existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        setSideNotes(id, text: existing + separator + entry)
        updateExchange(exchangeID, in: id) { $0.addedToSideNotes = true }
        show(.success, "Added to side notes", action: sideNotesVisible ? nil : "Show") { [weak self] in self?.toggleSideNotes() }
    }

    /// Opens the transcript at the turn a cited timestamp points to.
    func showTranscript(at seconds: TimeInterval) {
        let turns = displayedTranscript?.turns() ?? []
        guard !turns.isEmpty else { return }
        transcriptFocus = turns.lastIndex { $0.start <= seconds + 0.5 } ?? 0
        meetingTab = .transcript
    }
}

import SwiftUI
import HushKit
import MuesliCore

/// Questions about one meeting, answered from its notes, side notes and transcript.
struct AskView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    static let endID = "ask-end"
    private var exchanges: [AskExchange] { state.exchanges(for: meeting.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.block) {
            if exchanges.isEmpty { intro }
            ForEach(Array(exchanges.enumerated()), id: \.element.id) { index, exchange in
                if index > 0 { Divider().overlay(DesignTokens.hairline) }
                AskExchangeView(state: state, meeting: meeting, exchange: exchange).id(exchange.id)
            }
            Color.clear.frame(height: 1).id(Self.endID)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask about this meeting").font(DesignTokens.heading)
                Text(state.canAsk(meeting)
                     ? "Answers come from \(meeting.includesSideNotes && !meeting.userNotes.isEmpty ? "the notes, your side notes and the transcript" : "the notes and the transcript"). They stay on this page unless you keep one."
                     : "You can ask questions once this meeting's transcript or notes are ready.")
                    .font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
            }
            if state.canAsk(meeting) {
                FlowLayout(spacing: DesignTokens.space) {
                    ForEach(AskSuggestion.all, id: \.question) { suggestion in
                        Button(suggestion.question) { state.ask(suggestion.question, in: meeting.id) }
                            .buttonStyle(.hushSecondary).disabled(state.isAsking(meeting.id))
                    }
                }
            }
        }
        .padding(.top, DesignTokens.space)
    }
}

/// One question, its answer and what can be done with it.
struct AskExchangeView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    let exchange: AskExchange

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            Text(exchange.question).font(DesignTokens.section).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let answer = exchange.answer {
                Text(Self.attributed(answer, duration: state.displayedTranscript?.duration))
                    .font(DesignTokens.body).lineSpacing(DesignTokens.noteLineSpacing).foregroundStyle(DesignTokens.ink.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .tint(DesignTokens.soft) // Cited times look like the transcript's own timestamps.
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "hush-time", let seconds = TimeInterval(url.host() ?? "") else { return .systemAction }
                        state.showTranscript(at: seconds); return .handled
                    })
                footer
            } else if let error = exchange.error {
                HStack(alignment: .top, spacing: DesignTokens.space) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(DesignTokens.amber).font(.system(size: 13)).padding(.top, 1)
                    Text(error).font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: DesignTokens.space) {
                    Button("Try again") { state.retryAsk(exchange.id, in: meeting.id) }.buttonStyle(.hushSecondary).controlSize(.small)
                        .disabled(state.isAsking(meeting.id))
                    Button("AI model settings") { state.showSettings?(.models) }.buttonStyle(.hushQuiet).controlSize(.small)
                }
            } else {
                HStack(spacing: DesignTokens.space) {
                    ProgressView().controlSize(.small)
                    Text("Reading the meeting…").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
                    Spacer()
                    Button("Stop") { state.cancelAsk(meeting.id) }.buttonStyle(.hushQuiet).controlSize(.small)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Label(provenance, systemImage: exchange.onDevice ? "lock" : "arrow.up.forward.circle")
                if exchange.partial || exchange.notesShortened {
                    Label(exchange.notesShortened ? "Read part of the notes and transcript" : "Read the notes and part of the transcript", systemImage: "line.3.horizontal.decrease")
                        .help("This model reads a limited amount at once, so Hush chose the parts of the transcript that best match the question. A more specific question can help.")
                }
            }
            .labelStyle(FootnoteLabelStyle())
            Spacer(minLength: DesignTokens.space)
            IconButton(symbol: "doc.on.doc", help: "Copy answer") {
                state.copy(exchange.answer ?? ""); state.show(.success, "Answer copied")
            }
            IconButton(symbol: exchange.addedToSideNotes ? "checkmark" : "note.text.badge.plus",
                       help: exchange.addedToSideNotes ? "Added to side notes" : "Add to side notes") {
                state.addAnswerToSideNotes(exchange.id, in: meeting.id)
            }
            .disabled(exchange.addedToSideNotes)
        }
        .font(DesignTokens.small).foregroundStyle(DesignTokens.faint)
    }

    private var provenance: String {
        if state.isDemo { return "Sample answer for the preview. No model was used." }
        let name = exchange.source.components(separatedBy: ":").first ?? exchange.source
        return exchange.onDevice ? "Answered on this Mac by \(name)" : "Answered by \(name)"
    }

    /// Inline Markdown, with cited timestamps turned into links that open the transcript there.
    static func attributed(_ answer: String, duration: TimeInterval?) -> AttributedString {
        var result = AttributedString()
        var cursor = answer.startIndex
        func plain(_ text: Substring) {
            guard !text.isEmpty else { return }
            result += (try? AttributedString(markdown: String(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(String(text))
        }
        for citation in AskAnswer.citations(in: answer) {
            plain(answer[cursor..<citation.range.lowerBound])
            var stamp = AttributedString(String(answer[citation.range]))
            if duration.map({ citation.seconds <= $0 + 5 }) ?? false {
                stamp.link = URL(string: "hush-time://\(Int(citation.seconds))")
                stamp.font = DesignTokens.mono
            }
            result += stamp
            cursor = citation.range.upperBound
        }
        plain(answer[cursor...])
        return result
    }
}

private struct FootnoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 10)).frame(width: 12); configuration.title }
    }
}

/// Where questions are typed. Pinned to the bottom of the meeting page.
struct AskComposer: View {
    @Bindable var state: AppState
    let meeting: Meeting
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var enabled: Bool { state.canAsk(meeting) }
    private var canSend: Bool { enabled && !state.isAsking(meeting.id) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var providers: ProviderConfiguration { state.preferences.providers }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: DesignTokens.space) {
                TextField(enabled ? "Ask about this meeting" : "Available once the transcript is ready", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(DesignTokens.body).lineLimit(1...5).focused($focused)
                    .disabled(!enabled).onSubmit(send).padding(.vertical, 5)
                    .accessibilityLabel("Question about this meeting")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                        .foregroundStyle(canSend ? DesignTokens.paper : DesignTokens.faint)
                        .background(canSend ? DesignTokens.ink : DesignTokens.selected, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend).help("Ask (Return)").accessibilityLabel("Ask")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .strokeBorder(focused ? DesignTokens.ink.opacity(0.2) : DesignTokens.hairline))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
            Text(privacy).font(DesignTokens.small).foregroundStyle(DesignTokens.faint).lineLimit(1)
        }
        .frame(maxWidth: DesignTokens.pageWidth)
        .padding(.horizontal, DesignTokens.block + 8).padding(.top, DesignTokens.space).padding(.bottom, DesignTokens.gap)
        .frame(maxWidth: .infinity)
        .onAppear { if enabled { focused = true } }
        .onChange(of: meeting.id) { draft = "" }
    }

    private var privacy: String {
        if state.isDemo { return "Preview answers are samples. Nothing is sent or saved." }
        let notes = providers.notes
        if notes == .apple { return "Answered on this Mac. Nothing is saved unless you add it to side notes." }
        if notes.isLocalServer { return "Answered by your local model on this Mac. Nothing is saved unless you add it to side notes." }
        return "Questions go to \(notes == .compatible ? (providers.notesHost ?? "your server") : notes.name) with parts of this meeting."
    }

    private func send() {
        guard canSend else { return }
        state.ask(draft, in: meeting.id)
        if state.isAsking(meeting.id) { draft = "" }
    }
}

/// Wraps buttons onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

import SwiftUI
import AVFoundation
import Observation
import HushKit
import MuesliCore

/// Plays a meeting's two saved tracks together, aligned to the transcript clock.
@MainActor @Observable
final class MeetingPlayer {
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isAvailable = false
    var rate: Float = 1 { didSet { players.values.forEach { $0.rate = rate } } }
    @ObservationIgnored private var players: [Speaker: AVAudioPlayer] = [:]
    @ObservationIgnored private var offsets: [Speaker: TimeInterval] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private(set) var meetingID: UUID?

    func load(_ meeting: Meeting, store: MeetingStore?) async {
        stop(); players = [:]; isAvailable = false; duration = 0; position = 0
        meetingID = meeting.id
        guard let store else { return }
        for speaker in [Speaker.me, .them] {
            guard let data = try? await store.audioData(meeting.id, name: speaker.rawValue + ".wav"), data.count > 44,
                  let player = try? AVAudioPlayer(data: data) else { continue }
            guard meetingID == meeting.id else { return }
            player.enableRate = true; player.rate = rate; player.prepareToPlay()
            players[speaker] = player
            offsets[speaker] = meeting.audioOffsets?[speaker.rawValue] ?? 0
            duration = max(duration, player.duration + (offsets[speaker] ?? 0))
        }
        isAvailable = !players.isEmpty
    }
    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard isAvailable else { return }
        if position >= duration - 0.2 { position = 0 }
        let start = (players.values.first?.deviceCurrentTime ?? 0) + 0.05
        for (speaker, player) in players {
            let local = position - (offsets[speaker] ?? 0)
            if local >= 0 { player.currentTime = local; player.play(atTime: start) }
            else { player.currentTime = 0; player.play(atTime: start - local) }
        }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func pause() {
        players.values.forEach { $0.pause() }
        isPlaying = false; timer?.invalidate(); timer = nil
    }
    func stop() { pause(); position = 0 }
    func seek(_ time: TimeInterval) {
        let playing = isPlaying
        pause(); position = max(0, min(duration, time))
        if playing { play() }
    }
    private func refresh() {
        let times = players.map { speaker, player in player.isPlaying ? player.currentTime + (offsets[speaker] ?? 0) : 0 }
        position = times.max() ?? position
        if !players.values.contains(where: \.isPlaying) { isPlaying = false; timer?.invalidate(); timer = nil; if position >= duration - 0.5 { position = duration } }
    }
}

struct TranscriptView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    let transcript: Transcript?
    @State private var query = ""
    @State private var player = MeetingPlayer()
    @State private var renaming: Speaker?
    @State private var draftName = ""

    private var turns: [Transcript.Turn] { transcript?.turns() ?? [] }
    private var visible: [(offset: Int, element: Transcript.Turn)] {
        let all = Array(turns.enumerated())
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.element.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            toolbar
            if player.isAvailable { playerBar }
            if turns.isEmpty {
                Text(meeting.isProcessing ? "The transcript appears here when it's ready." : "No transcript was saved for this meeting.")
                    .font(DesignTokens.body).foregroundStyle(DesignTokens.soft).padding(.vertical, DesignTokens.block)
            } else if visible.isEmpty {
                Text("Nothing matches “\(query)”.").font(DesignTokens.body).foregroundStyle(DesignTokens.soft).padding(.vertical, DesignTokens.block)
            } else {
                LazyVStack(alignment: .leading, spacing: DesignTokens.inset) {
                    ForEach(visible, id: \.offset) { offset, turn in row(turn, focused: state.transcriptFocus == offset).id(Self.anchor(offset)) }
                }
            }
        }
        .task(id: meeting.id) { if !state.isDemo { await player.load(meeting, store: state.store) } }
        .onDisappear { player.pause() }
        .sheet(item: $renaming) { speaker in renameSheet(speaker) }
    }

    private var toolbar: some View {
        HStack(spacing: DesignTokens.space) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(DesignTokens.faint).font(.system(size: 12))
                TextField("Find in transcript", text: $query).textFieldStyle(.plain).font(DesignTokens.chrome)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DesignTokens.faint) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 260)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).strokeBorder(DesignTokens.hairline))
            if !query.isEmpty { Text("\(visible.count) of \(turns.count)").font(DesignTokens.small).foregroundStyle(DesignTokens.faint) }
            Spacer()
            ForEach([Speaker.me, .them], id: \.self) { speaker in
                Button { draftName = meeting.name(for: speaker); renaming = speaker } label: {
                    HStack(spacing: 5) {
                        Circle().fill(color(speaker)).frame(width: 7, height: 7)
                        Text(meeting.name(for: speaker)).font(DesignTokens.small)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).background(DesignTokens.selected, in: Capsule())
                }.buttonStyle(.plain).help("Rename \(meeting.name(for: speaker))")
            }
            IconButton(symbol: "doc.on.doc", help: "Copy transcript") {
                state.copy(Exporter.transcriptText(transcript, meeting: meeting)); state.show(.success, "Transcript copied")
            }.disabled(turns.isEmpty)
        }
    }

    private var playerBar: some View {
        HStack(spacing: DesignTokens.gap) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13)).frame(width: 30, height: 30)
                    .background(DesignTokens.ink, in: Circle()).foregroundStyle(DesignTokens.paper)
            }.buttonStyle(.plain).help(player.isPlaying ? "Pause" : "Play")
            Text(Transcript.timestamp(player.position)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration)).controlSize(.small)
            Text(Transcript.timestamp(player.duration)).font(DesignTokens.mono).foregroundStyle(DesignTokens.faint)
            Menu {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in Button(rate == 1 ? "Normal speed" : "\(rate.formatted())×") { player.rate = rate } }
            } label: { Text(player.rate == 1 ? "1×" : "\(player.rate.formatted())×").font(DesignTokens.small.monospacedDigit()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, DesignTokens.gap).padding(.vertical, DesignTokens.space)
        .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(DesignTokens.hairline))
    }

    /// Scroll target for one turn, used by cited timestamps in Ask.
    static func anchor(_ turn: Int) -> String { "turn-\(turn)" }

    private func row(_ turn: Transcript.Turn, focused: Bool = false) -> some View {
        let active = (player.isPlaying && player.position >= turn.start && player.position < turn.end + 1) || focused
        return HStack(alignment: .firstTextBaseline, spacing: DesignTokens.inset) {
            Button { player.isAvailable ? player.seek(turn.start) : () } label: {
                Text(Transcript.timestamp(turn.start)).font(DesignTokens.mono)
                    .foregroundStyle(player.isAvailable ? DesignTokens.soft : DesignTokens.faint)
            }
            .buttonStyle(.plain).frame(width: 52, alignment: .leading).disabled(!player.isAvailable)
            .help(player.isAvailable ? "Play from here" : "")
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.name(for: turn.speaker)).font(DesignTokens.chromeStrong).foregroundStyle(color(turn.speaker))
                Text(highlighted(turn.text)).font(DesignTokens.body).lineSpacing(DesignTokens.noteLineSpacing)
                    .foregroundStyle(DesignTokens.ink.opacity(0.88)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2).padding(.horizontal, active ? DesignTokens.space : 0)
        .background(active ? DesignTokens.selected : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let range = result[searchRange].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = DesignTokens.amber.opacity(0.25)
            searchRange = range.upperBound..<result.endIndex
        }
        return result
    }

    private func color(_ speaker: Speaker) -> Color { speaker == .me ? DesignTokens.ink : DesignTokens.them }

    private func renameSheet(_ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            Text("Rename “\(speaker.label)”").font(DesignTokens.heading)
            Text(speaker == .me ? "Your microphone." : "Everyone heard through system audio. In a one-to-one call, that's one person.")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            TextField(speaker.label, text: $draftName).textFieldStyle(.roundedBorder)
                .onSubmit { state.renameSpeaker(meeting.id, speaker: speaker, to: draftName); renaming = nil }
            HStack {
                Button("Reset") { state.renameSpeaker(meeting.id, speaker: speaker, to: ""); renaming = nil }
                Spacer()
                Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { state.renameSpeaker(meeting.id, speaker: speaker, to: draftName); renaming = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(DesignTokens.block).frame(width: 340)
    }
}


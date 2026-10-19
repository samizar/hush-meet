import SwiftUI
import HushKit
import MuesliCore

/// Two thin pen lines tracing voice levels, like a seismograph: Me in ink, Them in slate.
struct LiveLine: View {
    var capture: CaptureSession
    var height: CGFloat = DesignTokens.liveHeight
    var showLegend = true
    var meName = "Me"
    var themName = "Them"
    @Environment(\.hushReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: DesignTokens.space) {
            if reduceMotion {
                HStack(spacing: DesignTokens.inset) {
                    level(meName, capture.meLevels.last ?? 0, DesignTokens.ink)
                    level(themName, capture.themLevels.last ?? 0, DesignTokens.them)
                    Spacer()
                }.frame(height: 20)
            } else {
                Canvas { context, size in
                    for (levels, position, color) in [(capture.meLevels, 0.32, DesignTokens.ink), (capture.themLevels, 0.72, DesignTokens.them)] {
                        var path = Path()
                        for (index, level) in levels.enumerated() {
                            let x = size.width * Double(index) / Double(max(1, levels.count - 1))
                            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
                            let y = size.height * position + direction * level * size.height * 0.24
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: DesignTokens.lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }.frame(height: height)
                if showLegend {
                    HStack {
                        legend(meName, DesignTokens.ink, active: (capture.meLevels.last ?? 0) > 0.02)
                        Spacer()
                        legend(themName, DesignTokens.them, active: (capture.themLevels.last ?? 0) > 0.02)
                    }
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Voice levels for your microphone and the other side of the call.")
    }
    private func legend(_ name: String, _ color: Color, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(active ? 1 : 0.3)).frame(width: 6, height: 6)
            Text(name).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
        }
    }
    private func level(_ name: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(value > 0.02 ? 1 : 0.2)).frame(width: DesignTokens.dot, height: DesignTokens.dot)
            Text(name).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
        }
    }
}

/// The running transcript while recording. Settled words in ink, words still forming in a lighter tone.
struct LiveTranscript: View {
    var capture: CaptureSession
    var meeting: Meeting?
    var limit: Int? = nil
    private func name(_ speaker: Speaker) -> String { meeting?.name(for: speaker) ?? speaker.label }
    var body: some View {
        let turns = capture.transcript?.turns() ?? []
        let shown = limit.map { Array(turns.suffix($0)) } ?? turns
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            if shown.isEmpty && capture.volatileMe.isEmpty && capture.volatileThem.isEmpty {
                Text("Words appear here as people speak.").font(DesignTokens.body).foregroundStyle(DesignTokens.faint)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, turn in
                line(name(turn.speaker), turn.text, turn.speaker, settled: true)
            }
            if !capture.volatileMe.isEmpty { line(name(.me), capture.volatileMe, .me, settled: false) }
            if !capture.volatileThem.isEmpty { line(name(.them), capture.volatileThem, .them, settled: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func line(_ name: String, _ text: String, _ speaker: Speaker, settled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(DesignTokens.small.weight(.semibold)).foregroundStyle(speaker == .me ? DesignTokens.soft : DesignTokens.them)
            Text(text).font(DesignTokens.body).lineSpacing(4)
                .foregroundStyle(settled ? DesignTokens.ink.opacity(0.85) : DesignTokens.soft.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The meeting page while Hush is listening: timer, levels, your notes and the live transcript.
struct LiveMeetingView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    @FocusState private var notesFocused: Bool
    @State private var width: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.block) {
            header
            if let warning = state.capture.warning { warningCard(warning) }
            // Side by side when there's room for both; stacked in narrow windows.
            if width >= 620 {
                HStack(alignment: .top, spacing: DesignTokens.block) {
                    notes.frame(maxWidth: .infinity)
                    transcript.frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.block) { notes; transcript }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { notesFocused = true }
    }

    private var header: some View {
        Card(padding: DesignTokens.inset + 4) {
            VStack(alignment: .leading, spacing: DesignTokens.inset) {
                HStack(alignment: .center, spacing: DesignTokens.gap) {
                    RecordingDot(size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening").font(DesignTokens.heading)
                        Text(subtitle).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).lineLimit(1)
                    }
                    Spacer()
                    Text(Transcript.timestamp(state.elapsed)).font(DesignTokens.timer).foregroundStyle(DesignTokens.ink)
                        .contentTransition(.numericText()).accessibilityLabel("Elapsed time \(state.elapsed.spoken)")
                }
                LiveLine(capture: state.capture, meName: meeting.name(for: .me), themName: meeting.name(for: .them))
                HStack {
                    Label(state.preferences.providers.leavesMac ? state.preferences.providers.privacyLabel : "Transcribed on this Mac",
                          systemImage: state.preferences.providers.leavesMac ? "arrow.up.forward.circle" : "lock")
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    Spacer()
                    Button { state.stop() } label: {
                        HStack(spacing: 6) { Image(systemName: "stop.fill").font(.system(size: 10)); Text("Stop recording") }
                    }
                    .buttonStyle(HushButtonStyle(kind: .stop))
                    .disabled(state.isStopping)
                }
            }
        }
    }
    private var subtitle: String {
        var parts: [String] = []
        if let input = state.capture.inputName { parts.append(input) }
        if let attendees = meeting.attendees, !attendees.isEmpty { parts.append("with " + attendees.prefix(3).joined(separator: ", ") + (attendees.count > 3 ? " +\(attendees.count - 3)" : "")) }
        return parts.isEmpty ? "Both sides are being recorded on separate tracks." : parts.joined(separator: " · ")
    }

    private func warningCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.gap) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(DesignTokens.amber)
            Text(warning).font(DesignTokens.chrome).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let link = state.capture.settingsLink {
                Button("Open Settings") { NSWorkspace.shared.open(link) }.buttonStyle(.hushSecondary).controlSize(.small)
            }
        }
        .padding(DesignTokens.gap)
        .background(DesignTokens.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).strokeBorder(DesignTokens.amber.opacity(0.3)))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            HStack {
                SectionLabel("Your notes")
                Spacer()
                Text(state.savingIDs.contains(meeting.id) ? "Saving…" : "Saved").font(DesignTokens.small).foregroundStyle(DesignTokens.faint)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { state.liveNotes }, set: { state.setSideNotes(meeting.id, text: $0) }))
                    .font(DesignTokens.body).scrollContentBackground(.hidden).focused($notesFocused)
                    .lineSpacing(DesignTokens.noteLineSpacing)
                    .accessibilityLabel("Your notes for this meeting")
                if state.liveNotes.isEmpty {
                    Text("Jot down names, decisions, questions. Hush fills in the rest from the conversation.")
                        .font(DesignTokens.body).foregroundStyle(DesignTokens.faint).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .padding(DesignTokens.gap).frame(minHeight: 280)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(notesFocused ? DesignTokens.ink.opacity(0.2) : DesignTokens.hairline))
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            SectionLabel("Live transcript")
            ScrollViewReader { proxy in
                ScrollView {
                    LiveTranscript(capture: state.capture, meeting: meeting).padding(DesignTokens.gap)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(minHeight: 280, maxHeight: 520)
                .defaultScrollAnchor(.bottom)
                .onChange(of: state.capture.transcript?.segments.count) { withAnimation(DesignTokens.fade) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .background(DesignTokens.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(DesignTokens.hairline))
            if state.preferences.providers.transcription != .apple {
                Text("\(state.preferences.providers.transcription.name) transcribes after you stop.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
        }
    }
}

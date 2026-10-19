import SwiftUI
import HushKit
import MuesliCore

/// Side notes and details for the selected meeting, in the window's inspector.
struct InspectorView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.block) {
                SideNotesEditor(state: state, meeting: meeting)
                Divider()
                details
                Divider()
                actions
            }.padding(DesignTokens.inset)
        }
        .background(DesignTokens.sidebar.opacity(0.5))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            SectionLabel("Details")
            row("Started", meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
            if meeting.endedAt != nil { row("Length", meeting.duration.spoken) }
            row("Language", Locale.current.localizedString(forIdentifier: meeting.locale) ?? meeting.locale)
            row("Template", state.template(for: meeting)?.name ?? meeting.templateID)
            if let source = meeting.structuredNotes?.generatedBy { row("Written by", source.replacingOccurrences(of: ":", with: " · ")) }
            if let attendees = meeting.attendees, !attendees.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invited").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    Text(attendees.joined(separator: ", ")).font(DesignTokens.chrome).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            Spacer(minLength: DesignTokens.gap)
            Text(value).font(DesignTokens.chrome).multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            SectionLabel("Files")
            Button { state.revealFolder(meeting.id) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(.hushQuiet).disabled(state.isDemo)
            Button(role: .destructive) { state.delete(meeting.id) } label: { Label("Delete meeting…", systemImage: "trash") }
                .buttonStyle(.hushQuiet).disabled(!state.canDelete(meeting.id))
        }
    }
}

struct SideNotesEditor: View {
    @Bindable var state: AppState
    let meeting: Meeting
    @FocusState private var focused: Bool
    private var current: Meeting { state.meeting(meeting.id) ?? meeting }
    private var isLive: Bool { state.currentID == meeting.id }
    private var text: Binding<String> {
        Binding(get: { isLive ? state.liveNotes : current.userNotes }, set: { state.setSideNotes(meeting.id, text: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack {
                SectionLabel("Side notes")
                Spacer()
                Text(status).font(DesignTokens.small).foregroundStyle(state.saveErrors[meeting.id] != nil ? DesignTokens.ember : DesignTokens.faint)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(DesignTokens.chrome.leading(.loose)).scrollContentBackground(.hidden).focused($focused)
                    .accessibilityLabel("Side notes for this meeting")
                if text.wrappedValue.isEmpty {
                    Text("An agenda, names, questions — anything you want to keep. Hush can use it to write better notes.")
                        .font(DesignTokens.chrome).foregroundStyle(DesignTokens.faint).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(DesignTokens.space).frame(minHeight: 180)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).strokeBorder(focused ? DesignTokens.ink.opacity(0.2) : DesignTokens.hairline))
            Toggle(isOn: Binding(get: { current.includesSideNotes }, set: { state.setSideNotes(meeting.id, includeInContext: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use when writing notes").font(DesignTokens.chrome)
                    Text(current.includesSideNotes ? "Your text guides the notes. It's never changed." : "Kept for you only.")
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
            }.toggleStyle(.switch).controlSize(.small)
            if let error = state.saveErrors[meeting.id] {
                Text(error).font(DesignTokens.small).foregroundStyle(DesignTokens.ember)
                Button("Save again") { state.setSideNotes(meeting.id, text: current.userNotes) }.buttonStyle(.hushSecondary).controlSize(.small)
            }
            if current.includesSideNotes && state.preferences.providers.leavesMac && !state.preferences.providers.notes.isOnDevice {
                Text("Included side notes go to \(state.preferences.providers.notes.name) with the transcript.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
        }
    }
    private var status: String {
        if state.isDemo { return "Preview" }
        if state.saveErrors[meeting.id] != nil { return "Not saved" }
        return state.savingIDs.contains(meeting.id) ? "Saving…" : "Saved"
    }
}

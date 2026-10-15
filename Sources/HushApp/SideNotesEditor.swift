import SwiftUI
import HushKit

struct SideNotesEditor: View {
    @Bindable var state: AppState
    let meeting: Meeting
    private var current: Meeting { state.meetings.first { $0.id == meeting.id } ?? meeting }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack {
                Text("Side notes").font(DesignTokens.section)
                Spacer()
                Text(state.isDemo ? "Preview" : state.sideNotesSaving.contains(meeting.id) ? "Saving…" : state.sideNotesSaveErrors[meeting.id] != nil ? "Not saved" : "Saved on this Mac")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
            Text("Keep names, questions, an agenda, or thoughts you don't want to lose.")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { current.userNotes }, set: { state.setSideNotes(meeting.id, text: $0) }))
                    .font(DesignTokens.body).scrollContentBackground(.hidden)
                    .accessibilityLabel("Side notes for this meeting")
                if current.userNotes.isEmpty {
                    Text("A thought to keep, a question to ask…").font(DesignTokens.body).foregroundStyle(DesignTokens.faint)
                        .padding(.top, DesignTokens.smallGap).padding(.leading, DesignTokens.smallGap).allowsHitTesting(false)
                }
            }.frame(minHeight: 240, idealHeight: 300).padding(DesignTokens.space)
                .background(DesignTokens.paper, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                .disabled(state.busy)
            Toggle("Use as AI context", isOn: Binding(get: { current.includesSideNotes }, set: { state.setSideNotes(meeting.id, includeInContext: $0) }))
                .toggleStyle(.switch).font(DesignTokens.chrome).disabled(state.busy)
            Text(current.includesSideNotes ? "Included when AI writes or updates this meeting's notes. Your original text stays unchanged." : "Kept for you. Side notes aren't sent to the AI.")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
            if let error = state.sideNotesSaveErrors[meeting.id] {
                Text(error).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                Button("Save again") { state.setSideNotes(meeting.id, text: current.userNotes) }.buttonStyle(QuietButtonStyle())
            }
            if current.sideNotesChanged {
                Text("AI notes haven't been updated with these changes.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
            if current.transcriptionFinal && !state.capture.isRecording {
                Button(current.sideNotesChanged ? "Update AI notes" : "Regenerate AI notes") { state.retry(meeting.id) }
                    .buttonStyle(QuietButtonStyle(prominent: current.sideNotesChanged))
                    .disabled(state.busy || state.isDemo || state.sideNotesSaveErrors[meeting.id] != nil)
            }
            if current.includesSideNotes && state.preferences.providers.leavesMac {
                Text(state.preferences.providers.dataFlow).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

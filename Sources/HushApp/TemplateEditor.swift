import SwiftUI
import HushKit
import MuesliCore

/// Lists templates and edits one: its name, what the notes should focus on, and the layout.
struct TemplateSettings: View {
    @Bindable var state: AppState
    @State private var selectedID: String?
    @State private var draft: NoteTemplate?
    private var dirty: Bool { draft != state.templates.first { $0.id == selectedID } }
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(state.templates, selection: Binding(get: { selectedID }, set: { select($0) })) { template in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(DesignTokens.chrome)
                        Text(template.isBuiltIn ? (template.isModified ? "Built in · edited" : "Built in") : "Yours")
                            .font(DesignTokens.small).foregroundStyle(.secondary)
                    }.tag(template.id).padding(.vertical, 2)
                }
                Divider()
                HStack(spacing: 2) {
                    IconButton(symbol: "plus", help: "New template") { create() }.disabled(state.isDemo)
                    IconButton(symbol: "plus.square.on.square", help: "Duplicate") { duplicate() }.disabled(draft == nil || state.isDemo)
                    IconButton(symbol: "minus", help: "Remove") { remove() }.disabled(draft?.isBuiltIn != false || state.isDemo)
                    Spacer()
                    IconButton(symbol: "folder", help: "Show templates in Finder") { NSWorkspace.shared.open(Templates.directory) }.disabled(state.isDemo)
                }.padding(6)
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
            editor.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { state.reloadTemplates(); if selectedID == nil { select(state.templates.first?.id) } }
    }

    @ViewBuilder private var editor: some View {
        if let binding = Binding($draft) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.inset) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Name")
                        TextField("Template name", text: binding.name).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("What to focus on")
                        TextEditor(text: binding.instruction).font(DesignTokens.chrome).frame(minHeight: 70, maxHeight: 110)
                            .scrollContentBackground(.hidden).padding(6)
                            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline))
                        Text("A short instruction for the notes model, like “Focus on customer needs and next steps.”").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Layout")
                        TextEditor(text: binding.layout).font(.system(size: 12.5).monospaced()).frame(minHeight: 200)
                            .scrollContentBackground(.hidden).padding(6)
                            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Templates.placeholders, id: \.key) { item in
                                    Button { binding.wrappedValue.layout += "{{\(item.key)}}" } label: { Chip(item.label, symbol: "plus") }
                                        .buttonStyle(.plain).help("Insert {{\(item.key)}}")
                                }
                            }
                        }
                    }
                    if let error { Text(error).font(DesignTokens.small).foregroundStyle(DesignTokens.ember) }
                    HStack {
                        if binding.wrappedValue.isBuiltIn && binding.wrappedValue.isModified {
                            Button("Restore Original") { restore() }
                        }
                        Spacer()
                        Button("Revert") { select(selectedID) }.disabled(!dirty)
                        Button("Save") { save() }.keyboardShortcut("s", modifiers: .command).disabled(!dirty || state.isDemo)
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Meetings that use this template keep their notes until you write them again.").font(DesignTokens.small).foregroundStyle(DesignTokens.faint)
                }.padding(DesignTokens.inset)
            }
        } else {
            Text("Choose a template.").foregroundStyle(DesignTokens.soft).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ id: String?) {
        selectedID = id; draft = state.templates.first { $0.id == id }; error = nil
    }
    private func save() {
        guard let draft else { return }
        do { try Templates.save(draft); state.reloadTemplates(); select(draft.id); state.show(.success, "Template saved") }
        catch { self.error = error.localizedDescription }
    }
    private func create() {
        do { let template = try Templates.create(named: "New template"); state.reloadTemplates(); select(template.id) }
        catch { self.error = error.localizedDescription }
    }
    private func duplicate() {
        guard let draft else { return }
        do {
            let url = try Templates.duplicate(draft); state.reloadTemplates()
            select(url.deletingPathExtension().lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let draft, !draft.isBuiltIn else { return }
        let inUse = state.meetings.filter { $0.templateID == draft.id }.count
        let alert = NSAlert(); alert.messageText = "Remove “\(draft.name)”?"
        alert.informativeText = inUse == 0 ? "This removes the template file." : "\(inUse) meetings use it. Their notes stay; writing them again uses the first template."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Templates.remove(draft); state.reloadTemplates(); select(state.templates.first?.id) }
        catch { self.error = error.localizedDescription }
    }
    private func restore() {
        guard let draft else { return }
        do { _ = try Templates.restore(draft); state.reloadTemplates(); select(draft.id) }
        catch { self.error = error.localizedDescription }
    }
}

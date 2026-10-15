import Foundation
import MuesliCore

public struct NoteTemplate: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var instruction: String
    public var layout: String
    public var url: URL
    public init(url: URL, contents: String) {
        self.url = url; id = url.deletingPathExtension().lastPathComponent
        let parts = contents.components(separatedBy: "\n---\n")
        let lines = (parts.first ?? "").components(separatedBy: "\n")
        name = lines.first?.replacingOccurrences(of: "# ", with: "") ?? id
        instruction = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        layout = parts.dropFirst().joined(separator: "\n---\n")
    }
    public func render(_ notes: MeetingNotes) -> String {
        func bullets(_ lines: [String]) -> String { lines.isEmpty ? "Nothing noted." : lines.map { "- " + $0 }.joined(separator: "\n") }
        let actions = notes.actionItems.map { item in
            "- [ ] " + item.title + (item.owner.map { " — " + $0 } ?? "") + ((item.dueDate ?? item.dueText).map { " · " + $0 } ?? "")
        }
        let table = notes.decisions.isEmpty ? "No decisions recorded." : "| Decision |\n| --- |\n" + notes.decisions.map { "| " + $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") + " |" }.joined(separator: "\n")
        let replacements = ["title": notes.title, "summary": notes.summary,
                            "key_points": bullets(notes.keyPoints), "decisions": bullets(notes.decisions),
                            "decisions_table": table, "action_items": actions.isEmpty ? "No action items." : actions.joined(separator: "\n"),
                            "open_questions": bullets(notes.openQuestions), "user_notes": notes.enhancedNotes ?? ""]
        var result = layout.isEmpty ? "# {{title}}\n\n{{summary}}\n\n## Action items\n{{action_items}}" : layout
        for (key, value) in replacements { result = result.replacingOccurrences(of: "{{" + key + "}}", with: value) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

public enum Templates {
    public static var directory: URL { MeetingStore.supportRoot.appendingPathComponent("Templates", isDirectory: true) }
    public static func load(directory: URL = directory) throws -> [NoteTemplate] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (id, text) in builtIns {
            let url = directory.appendingPathComponent(id + ".md")
            if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let order = ["quick", "standard", "detailed", "one-on-one", "sales", "interview"]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.map { NoteTemplate(url: $0, contents: try String(contentsOf: $0, encoding: .utf8)) }
            .sorted { (order.firstIndex(of: $0.id) ?? 100, $0.name) < (order.firstIndex(of: $1.id) ?? 100, $1.name) }
    }
    public static func duplicate(_ template: NoteTemplate) throws -> URL {
        let url = template.url.deletingLastPathComponent().appendingPathComponent(template.id + "-" + String(UUID().uuidString.prefix(6)) + ".md")
        let content = "# " + template.name + " copy\n\n" + template.instruction + "\n---\n" + template.layout
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    public static let builtIns: [(String, String)] = [
        ("quick", """
        # Quick

        Write a three-sentence summary and only concrete action items. Keep it brief.
        ---
        # {{title}}

        {{summary}}

        ## Action items
        {{action_items}}

        {{user_notes}}
        """),
        ("standard", """
        # Standard

        Capture the main discussion, decisions, commitments and unanswered questions.
        ---
        # {{title}}

        {{summary}}

        ## Key points
        {{key_points}}

        ## Decisions
        {{decisions}}

        ## Action items
        {{action_items}}

        ## Open questions
        {{open_questions}}

        {{user_notes}}
        """),
        ("detailed", """
        # Detailed

        Preserve relevant detail, reasons behind decisions and all commitments. Use clear, complete sentences.
        ---
        # {{title}}

        ## Summary
        {{summary}}

        ## Discussion
        {{key_points}}

        ## Decisions
        {{decisions_table}}

        ## Action items
        {{action_items}}

        ## Open questions
        {{open_questions}}

        {{user_notes}}
        """),
        ("one-on-one", """
        # 1:1

        Focus on the person's priorities, wellbeing, feedback, blockers and agreed next steps. Never infer emotions.
        ---
        # {{title}}

        {{summary}}

        ## What came up
        {{key_points}}

        ## Agreements
        {{decisions}}

        ## Before next time
        {{action_items}}

        ## To revisit
        {{open_questions}}

        {{user_notes}}
        """),
        ("sales", """
        # Sales call

        Focus on customer needs, pain points, objections, buying criteria, budget if stated, and agreed next steps. Do not invent sales qualification.
        ---
        # {{title}}

        {{summary}}

        ## Needs and context
        {{key_points}}

        ## Agreed
        {{decisions}}

        ## Next steps
        {{action_items}}

        ## Still to learn
        {{open_questions}}

        {{user_notes}}
        """),
        ("interview", """
        # Interview

        Capture questions, answers and specific evidence. Distinguish observations from opinions. Do not infer protected characteristics or recommend hiring decisions.
        ---
        # {{title}}

        {{summary}}

        ## Conversation and evidence
        {{key_points}}

        ## Conclusions stated
        {{decisions}}

        ## Follow-up
        {{action_items}}

        ## Unanswered
        {{open_questions}}

        {{user_notes}}
        """)
    ]
}

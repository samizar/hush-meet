import SwiftUI
import HushKit

/// One rendered piece of a notes page.
enum NoteBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(level: Int, text: String)
    case numbered(level: Int, marker: String, text: String)
    case task(line: Int, level: Int, done: Bool, text: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
    case code(String)
}

/// A small Markdown parser for the subset templates and people write: headings, paragraphs,
/// nested bullets, numbered lists, checklists, tables, quotes, rules and code fences.
enum NoteParser {
    static let placeholders: Set<String> = ["Nothing noted.", "No action items.", "No decisions recorded."]

    static func blocks(_ markdown: String, omitTitle: Bool = false) -> [NoteBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?
        var skippedTitle = !omitTitle
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let header = table[0]
            blocks.append(.table(header: header, rows: Array(table.dropFirst())))
            table = []
        }
        for (index, raw) in lines.enumerated() {
            if var fence = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { blocks.append(.code(fence.joined(separator: "\n"))); code = nil }
                else { fence.append(raw); code = fence }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = min(4, indent / 2)
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = tableCells(line)
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { table.append(Array(cells)) }
                continue
            }
            flushTable()
            if line.isEmpty { flushParagraph(); continue }
            if line.hasPrefix("```") { flushParagraph(); code = []; continue }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if hashes <= 6, line.dropFirst(hashes).first == " " {
                    flushParagraph()
                    let text = String(line.dropFirst(hashes + 1))
                    if hashes == 1 && !skippedTitle { skippedTitle = true; continue }
                    blocks.append(.heading(level: hashes, text: text)); continue
                }
            }
            if let task = NotesMarkdown.task(in: raw) {
                flushParagraph(); blocks.append(.task(line: index, level: level, done: task.done, text: task.text)); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph(); blocks.append(.bullet(level: level, text: String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].first == " " {
                flushParagraph()
                blocks.append(.numbered(level: level, marker: String(line[...dot]), text: String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            if line.hasPrefix(">") { flushParagraph(); blocks.append(.quote(String(line.drop { $0 == ">" || $0 == " " }))); continue }
            if line == "---" || line == "***" || line == "___" { flushParagraph(); blocks.append(.rule); continue }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph(); flushTable()
        return blocks
    }

    /// Cells of a `| a | b |` row. An escaped `\|` stays inside its cell.
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped { current.append(character == "|" ? "|" : "\\" + String(character)); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(current); current = "" }
            else { current.append(character) }
        }
        cells.append(current)
        // Drop the empty edges outside the first and last pipes.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits "Send the deck — Sam · 2026-10-21" into its parts.
    static func taskParts(_ text: String) -> (title: String, owner: String?, due: String?) {
        let pieces = text.components(separatedBy: " — ")
        guard pieces.count > 1 else {
            let dated = text.components(separatedBy: " · ")
            return dated.count > 1 ? (dated.dropLast().joined(separator: " · "), nil, dated.last) : (text, nil, nil)
        }
        let title = pieces.dropLast().joined(separator: " — ")
        let meta = pieces.last!.components(separatedBy: " · ")
        return (title, meta.first.flatMap { $0.isEmpty ? nil : $0 }, meta.count > 1 ? meta.dropFirst().joined(separator: " · ") : nil)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Shows ISO due dates as "Fri, Oct 24".
    static func friendlyDue(_ raw: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        guard raw.count == 10, let date = formatter.date(from: raw) else { return raw }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Renders notes like a well-set page. Checklists are interactive.
struct MarkdownView: View {
    let markdown: String
    var omitTitle = true
    var animate = true
    var onToggle: ((Int, String) -> Void)?
    @Environment(\.hushReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let blocks = NoteParser.blocks(markdown, omitTitle: omitTitle)
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block)
                    .opacity(appeared || !animate ? 1 : 0)
                    .offset(y: appeared || !animate || reduceMotion ? 0 : DesignTokens.dryingOffset)
                    .animation(animate ? DesignTokens.fade.delay(min(1.2, Double(index) * DesignTokens.stagger)) : nil, value: appeared)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onAppear { appeared = true }
    }

    @ViewBuilder private func view(_ block: NoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(NoteParser.inline(text))
                .font(level <= 1 ? DesignTokens.title : level == 2 ? DesignTokens.heading : DesignTokens.section)
                .padding(.top, level <= 2 ? DesignTokens.inset : DesignTokens.space)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            prose(text)
        case .bullet(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.gap) {
                Circle().fill(level == 0 ? DesignTokens.soft : DesignTokens.faint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                prose(text)
            }.padding(.leading, CGFloat(level) * DesignTokens.indent)
        case .numbered(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space) {
                Text(marker).font(DesignTokens.body.monospacedDigit()).foregroundStyle(DesignTokens.soft).frame(minWidth: 18, alignment: .trailing)
                prose(text)
            }.padding(.leading, CGFloat(level) * DesignTokens.indent)
        case .task(let line, let level, let done, let text):
            TaskRow(text: text, done: done) { onToggle?(line, text) }
                .disabled(onToggle == nil)
                .padding(.leading, CGFloat(level) * DesignTokens.indent)
        case .table(let header, let rows):
            NoteTable(header: header, rows: rows)
        case .quote(let text):
            HStack(spacing: DesignTokens.gap) {
                RoundedRectangle(cornerRadius: 1).fill(DesignTokens.hairline).frame(width: 3)
                prose(text).foregroundStyle(DesignTokens.soft)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider).padding(.vertical, DesignTokens.space)
        case .code(let text):
            Text(text).font(.system(size: 13).monospaced()).padding(DesignTokens.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.well, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        }
    }

    private func prose(_ text: String) -> some View {
        let placeholder = NoteParser.placeholders.contains(text)
        return Text(NoteParser.inline(text))
            .font(placeholder ? DesignTokens.body.italic() : DesignTokens.body)
            .foregroundStyle(placeholder ? DesignTokens.faint : DesignTokens.ink)
            .lineSpacing(DesignTokens.noteLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TaskRow: View {
    let text: String
    let done: Bool
    var meetingTitle: String?
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        let parts = NoteParser.taskParts(text)
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.gap) {
            Button(action: toggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(done ? DesignTokens.sage : hovering ? DesignTokens.ink : DesignTokens.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 5) {
                Text(NoteParser.inline(parts.title)).font(DesignTokens.body)
                    .strikethrough(done, color: DesignTokens.faint)
                    .foregroundStyle(done ? DesignTokens.faint : DesignTokens.ink)
                    .lineSpacing(DesignTokens.noteLineSpacing).fixedSize(horizontal: false, vertical: true)
                if parts.owner != nil || parts.due != nil || meetingTitle != nil {
                    HStack(spacing: 6) {
                        if let owner = parts.owner { Chip(owner, symbol: owner == "Me" ? "person.fill" : "person") }
                        if let due = parts.due { Chip(NoteParser.friendlyDue(due), symbol: "calendar") }
                        if let meetingTitle { Text(meetingTitle).font(DesignTokens.small).foregroundStyle(DesignTokens.faint).lineLimit(1) }
                    }
                }
            }
        }
        .animation(DesignTokens.quick, value: done)
    }
}

struct NoteTable: View {
    let header: [String]
    let rows: [[String]]
    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.inset, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    Text(NoteParser.inline(header.indices.contains(column) ? header[column] : "")).font(DesignTokens.chromeStrong).foregroundStyle(DesignTokens.soft)
                        .padding(.vertical, DesignTokens.space)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(NoteParser.inline(row.indices.contains(column) ? row[column] : "")).font(DesignTokens.body)
                            .lineSpacing(DesignTokens.noteLineSpacing).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, DesignTokens.space)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.gap).padding(.vertical, DesignTokens.smallGap)
        .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).strokeBorder(DesignTokens.hairline))
    }
}

import AppKit
import CoreText
import UniformTypeIdentifiers
import HushKit
import MuesliCore

@MainActor
enum Exporter {
    /// Notes ready to leave Hush: the meeting's own title and a date line replace the model's heading.
    static func cleanMarkdown(_ markdown: String, meeting: Meeting) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[first].hasPrefix("# ") {
            lines.remove(at: first)
        }
        var header = "# \(meeting.title)\n\n"
        var meta = [meeting.startedAt.formatted(date: .long, time: .shortened)]
        if meeting.endedAt != nil { meta.append(meeting.duration.spoken) }
        if let attendees = meeting.attendees, !attendees.isEmpty { meta.append("With " + attendees.joined(separator: ", ")) }
        header += "_" + meta.joined(separator: " · ") + "_\n"
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return header + "\n" + body + "\n"
    }

    static func transcriptText(_ transcript: Transcript?, meeting: Meeting) -> String {
        guard let transcript else { return "" }
        return transcript.turns().map { "[\(Transcript.timestamp($0.start))] \(meeting.name(for: $0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    static func markdown(_ text: String, title: String) {
        let panel = savePanel(title: title, type: UTType(filenameExtension: "md") ?? .plainText, extension: "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { showError("Couldn't save Markdown. Choose another location and try again.") }
    }
    static func saveTranscript(_ transcript: Transcript?, meeting: Meeting) {
        guard let transcript else { return }
        let panel = savePanel(title: meeting.title + " transcript", type: .plainText, extension: "txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = meeting.title + "\n" + meeting.startedAt.formatted(date: .long, time: .shortened) + "\n\n" + transcriptText(transcript, meeting: meeting) + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { showError("Couldn't save the transcript. Choose another location and try again.") }
    }
    static func pdf(_ markdown: String, meeting: Meeting) {
        let panel = savePanel(title: meeting.title, type: .pdf, extension: "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pdfData(markdown, meeting: meeting).write(to: url, options: .atomic) }
        catch { showError("Couldn't save the PDF. Choose another location and try again.") }
    }

    /// Puts rich text and HTML on the pasteboard, with plain Markdown as a fallback.
    static func copyRich(_ markdown: String, meeting: Meeting) {
        let clean = cleanMarkdown(markdown, meeting: meeting)
        let attributed = attributedMarkdown(clean, forScreen: true)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let range = NSRange(location: 0, length: attributed.length)
        if let rtf = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let html = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            pasteboard.setData(html, forType: .html)
        }
        pasteboard.setString(clean, forType: .string)
    }

    /// Opens a new Mail message with the notes. Nothing is sent until the person sends it.
    static func email(_ markdown: String, meeting: Meeting) {
        let body = cleanMarkdown(markdown, meeting: meeting)
            .replacingOccurrences(of: "- [ ] ", with: "☐ ").replacingOccurrences(of: "- [x] ", with: "☑ ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "## ", with: "").replacingOccurrences(of: "# ", with: "")
        guard let service = NSSharingService(named: .composeEmail) else { showError("No email app is set up on this Mac."); return }
        service.subject = meeting.title
        service.perform(withItems: [body])
    }

    static func pdfData(_ markdown: String, meeting: Meeting) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw HushError.message("Couldn't prepare a PDF.") }
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: meeting.title] as CFDictionary) else { throw HushError.message("Couldn't prepare a PDF.") }
        let document = attributedMarkdown(markdown, forScreen: false)
        let framesetter = CTFramesetterCreateWithAttributedString(document)
        let textRect = page.insetBy(dx: 60, dy: 66)
        var position = 0; var pageNumber = 1
        while position < document.length {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(page)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "\(meeting.title)   ·   \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))   ·   \(pageNumber)", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .regular), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
            context.textPosition = CGPoint(x: textRect.minX, y: 34); CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw HushError.message("Couldn't fit notes on a PDF page.") }
            position += visible.length; pageNumber += 1
        }
        context.closePDF(); return output as Data
    }

    static func attributedMarkdown(_ markdown: String, forScreen: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let ink = forScreen ? NSColor.textColor : NSColor(red: 26.0/255, green: 25.0/255, blue: 22.0/255, alpha: 1)
        let soft = forScreen ? NSColor.secondaryLabelColor : NSColor(white: 0.42, alpha: 1)
        func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }
        for line in markdown.components(separatedBy: .newlines) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.4; paragraph.paragraphSpacing = 6
            var text = line; var face = font(14); var color = ink
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if text.hasPrefix("# ") { text = String(text.dropFirst(2)); face = font(22, .semibold); paragraph.paragraphSpacing = 4 }
            else if text.hasPrefix("## ") { text = String(text.dropFirst(3)); face = font(15, .semibold); paragraph.paragraphSpacingBefore = 14 }
            else if text.hasPrefix("### ") { text = String(text.dropFirst(4)); face = font(14, .semibold); paragraph.paragraphSpacingBefore = 10 }
            else if let task = NotesMarkdown.task(in: text) { text = (task.done ? "☑  " : "☐  ") + task.text; paragraph.headIndent = 20 }
            else if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "•  " + text.dropFirst(2); paragraph.headIndent = 14 }
            else if text.hasPrefix("| ---") || text.hasPrefix("|---") { continue }
            else if text.hasPrefix("|") { text = NoteParser.tableCells(text).joined(separator: "     ") }
            else if text.hasPrefix("_") && text.hasSuffix("_") { text = String(text.dropFirst().dropLast()); face = font(11.5); color = soft; paragraph.paragraphSpacing = 14 }
            let parsed = (try? AttributedString(markdown: text + "\n", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text + "\n")
            let attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            let whole = NSRange(location: 0, length: attributed.length)
            attributed.addAttributes([.foregroundColor: color, .paragraphStyle: paragraph], range: whole)
            // Keep bold and italic from inline Markdown while applying the line's size.
            attributed.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                let base = traits.isEmpty ? face : NSFont(descriptor: face.fontDescriptor.withSymbolicTraits(traits), size: face.pointSize) ?? face
                attributed.addAttribute(.font, value: base, range: range)
            }
            if attributed.attribute(.font, at: 0, effectiveRange: nil) == nil { attributed.addAttribute(.font, value: face, range: whole) }
            output.append(attributed)
        }
        return output
    }
    private static func savePanel(title: String, type: UTType, extension suffix: String) -> NSSavePanel {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.canCreateDirectories = true
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = String(safe.prefix(120)) + "." + suffix
        return panel
    }
    private static func showError(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
}

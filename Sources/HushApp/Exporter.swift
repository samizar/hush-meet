import AppKit
import CoreText
import UniformTypeIdentifiers
import HushKit

@MainActor
enum Exporter {
    static func markdown(_ text: String, title: String) {
        let panel = savePanel(title: title, type: UTType(filenameExtension: "md") ?? .plainText, extension: "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { showError("Couldn't save Markdown. Choose another location and try again.") }
    }
    static func pdf(_ markdown: String, meeting: Meeting) {
        let panel = savePanel(title: meeting.title, type: .pdf, extension: "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pdfData(markdown, meeting: meeting).write(to: url, options: .atomic) }
        catch { showError("Couldn't save the PDF. Choose another location and try again.") }
    }
    static func pdfData(_ markdown: String, meeting: Meeting) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw HushError.message("Couldn't prepare a PDF.") }
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: meeting.title] as CFDictionary) else { throw HushError.message("Couldn't prepare a PDF.") }
        let document = attributedMarkdown(markdown)
        let framesetter = CTFramesetterCreateWithAttributedString(document)
        let textRect = page.insetBy(dx: 54, dy: 64)
        var position = 0; var pageNumber = 1
        while position < document.length {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 247.0/255, green: 245.0/255, blue: 240.0/255, alpha: 1)); context.fill(page)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "HUSH   /   \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))   /   \(pageNumber)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            context.textPosition = CGPoint(x: textRect.minX, y: 32); CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw HushError.message("Couldn't fit notes on a PDF page.") }
            position += visible.length; pageNumber += 1
        }
        context.closePDF(); return output as Data
    }
    private static func attributedMarkdown(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func body(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: weight)
        }
        for line in markdown.components(separatedBy: .newlines) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.5; paragraph.paragraphSpacing = 7
            var text = line; var font = body(15)
            if text.hasPrefix("# ") { text = String(text.dropFirst(2)); font = body(22, .medium); paragraph.paragraphSpacing = 18 }
            else if text.hasPrefix("## ") { text = String(text.dropFirst(3)); font = body(15, .medium); paragraph.paragraphSpacingBefore = 14 }
            else if text.hasPrefix("### ") { text = String(text.dropFirst(4)); font = body(16, .medium); paragraph.paragraphSpacingBefore = 10 }
            else if text.hasPrefix("- [ ] ") { text = "☐  " + text.dropFirst(6); paragraph.headIndent = 20 }
            else if text.hasPrefix("- [x] ") { text = "☑  " + text.dropFirst(6); paragraph.headIndent = 20 }
            else if text.hasPrefix("- ") { text = "–  " + text.dropFirst(2); paragraph.headIndent = 14 }
            else if text.hasPrefix("| ---") { continue }
            else if text.hasPrefix("|") { text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "     ") }
            let parsed = (try? AttributedString(markdown: text + "\n", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text + "\n")
            let attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            attributed.addAttributes([.font: font, .foregroundColor: NSColor(red: 26.0/255, green: 25.0/255, blue: 22.0/255, alpha: 1),
                                      .paragraphStyle: paragraph], range: NSRange(location: 0, length: attributed.length))
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

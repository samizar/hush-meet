import Foundation
import Testing
import PDFKit
import HushKit
@testable import HushApp

@Suite("PDF export")
@MainActor
struct ExportTests {
    @Test func paginatesAndKeepsEveryLine() throws {
        let meeting = Meeting(title: "Export proof")
        let lines = (0..<100).map { "- Point \($0): A clear decision with an owner and a next step." }
        let markdown = "# Export proof\n\nA **careful** summary.\n\n## Decisions\n" + lines.joined(separator: "\n") + "\n\nEND OF NOTES"
        let bytes = try Exporter.pdfData(markdown, meeting: meeting)
        let document = try #require(PDFDocument(data: bytes))
        #expect(document.pageCount > 1)
        let text = document.string ?? ""
        #expect(text.contains("Export proof")); #expect(text.contains("END OF NOTES"))
        #expect(!text.contains("**careful**"))
        for number in 0..<100 { #expect(text.contains("Point \(number):")) }
    }
}

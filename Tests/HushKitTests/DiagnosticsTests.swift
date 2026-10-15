import Foundation
import Testing
@testable import HushKit

@Suite("Private diagnostics")
struct DiagnosticsTests {
    @Test func logsOnlyFixedEventsAndNumbers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(directory: folder)
        log.record(.processingFailed, count: 2, error: NSError(domain: "private-meeting-title", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "transcript-and-secret-api-key"]))
        let file = folder.appendingPathComponent("pipeline.log")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("event=processingFailed count=2 errorCode=17"))
        #expect(!text.contains("private-meeting")); #expect(!text.contains("transcript-and-secret"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test func rotatesToTwoSmallLocalFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(directory: folder, byteLimit: 100)
        for _ in 0..<20 { log.record(.stopRequested) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        #expect(Set(files.map(\.lastPathComponent)) == ["pipeline.log", "pipeline.previous.log"])
        for file in files { #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! < 200) }
    }
}

import DonkeyHarness
import Foundation
import Testing

@Suite
struct FileToolSupportTests {
    @Test
    func resolvesRegularFilesInDirectorySkippingHiddenAndSubdirs() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fts-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: dir.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        try "z".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let (files, truncated) = FileToolSupport.resolveFiles(directory: dir.path, paths: [], maxFiles: 50)
        #expect(!truncated)
        #expect(files.map(\.lastPathComponent) == ["one.txt", "two.md"])
    }

    @Test
    func explicitPathsWinOverDirectory() {
        let (files, _) = FileToolSupport.resolveFiles(directory: "/tmp", paths: ["/tmp/a.txt", "/tmp/b.txt"], maxFiles: 50)
        #expect(files.map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }

    @Test
    func capTruncatesLargeSets() {
        let paths = (0..<10).map { "/tmp/f\($0).txt" }
        let (files, truncated) = FileToolSupport.resolveFiles(directory: nil, paths: paths, maxFiles: 3)
        #expect(files.count == 3)
        #expect(truncated)
    }
}

@Suite
struct FileUnderstandingEngineTests {
    @Test
    func classifiesByExtensionThroughTheTypeRegistry() {
        #expect(FileUnderstandingEngine.classify(fileExtension: "md") == .text)
        #expect(FileUnderstandingEngine.classify(fileExtension: "swift") == .text)
        #expect(FileUnderstandingEngine.classify(fileExtension: "PNG") == .image)
        #expect(FileUnderstandingEngine.classify(fileExtension: "heic") == .image)
        #expect(FileUnderstandingEngine.classify(fileExtension: "pdf") == .pdf)
        #expect(FileUnderstandingEngine.classify(fileExtension: "m4a") == .audio)
        #expect(FileUnderstandingEngine.classify(fileExtension: "mov") == .video)
        #expect(FileUnderstandingEngine.classify(fileExtension: "zzznotatype") == .unknown)
    }

    @Test
    func textFileUnderstandingReadsContent() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("fue-\(UUID().uuidString).txt")
        try "Hello, this is the body of a note about budgets.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: url) }
        let u = FileUnderstandingEngine.foundationUnderstanding(for: url)
        #expect(u.kind == .text)
        #expect(u.textContent.contains("budgets"))
        #expect(u.fileExtension == "txt")
    }

    @Test
    func binaryFileUnderstandingHasNoTextAndIsClassifiedBinary() throws {
        let fm = FileManager.default
        // Unknown extension with binary content sniffs to .binary, not .text.
        let url = fm.temporaryDirectory.appendingPathComponent("fue-\(UUID().uuidString).zzznotatype")
        try Data([0x00, 0x01, 0x02, 0x00, 0xFF]).write(to: url)
        defer { try? fm.removeItem(at: url) }
        let u = FileUnderstandingEngine.foundationUnderstanding(for: url)
        #expect(u.kind == .binary)
        #expect(u.textContent.isEmpty)
        #expect(u.summary.contains("no readable text content"))
    }

    @Test
    func contentForReasoningFallsBackToSummaryWhenNoText() {
        let u = FileUnderstanding(
            path: "/tmp/a.heic",
            fileName: "a.heic",
            fileExtension: "heic",
            kind: .image,
            textContent: "",
            summary: "image (.heic), 4032x3024, no readable text content"
        )
        #expect(u.contentForReasoning(limit: 1_000).contains("4032x3024"))
    }
}

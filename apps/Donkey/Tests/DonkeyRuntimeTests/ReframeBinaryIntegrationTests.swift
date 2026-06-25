import AVFoundation
import Foundation
import Testing

// End-to-end test of the real `reframe` binary: it compiles the CLI (tools/reframe/main.swift +
// ReframePlanner.swift, exactly as scripts/fetch-bundled-tools.sh does), runs it on a committed
// video fixture, and verifies the PRODUCED vertical file with AVFoundation — real output, not a mock.
//
// Opt-in (it compiles Swift and exports video, ~15s): run with
//   DONKEY_REFRAME_E2E=1 swift test --filter ReframeBinaryIntegrationTests
@Suite
struct ReframeBinaryIntegrationTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DONKEY_REFRAME_E2E"] == "1" }

    // .../apps/Donkey/Tests/DonkeyRuntimeTests/ThisFile.swift -> repo root is four levels up.
    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // DonkeyRuntimeTests
        for _ in 0..<4 { url = url.deletingLastPathComponent() }              // Tests, Donkey, apps, root
        return url
    }

    @discardableResult
    static func run(_ tool: URL, _ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, err)
    }

    @Test(.enabled(if: ReframeBinaryIntegrationTests.enabled))
    func producesAVerticalClipWithAudioFromARealVideo() async throws {
        let root = Self.repoRoot()
        let mainSwift = root.appendingPathComponent("tools/reframe/main.swift")
        let plannerSwift = root.appendingPathComponent("apps/Donkey/Sources/DonkeyRuntime/ReframePlanner.swift")
        let fixture = root.appendingPathComponent("apps/Donkey/Tests/DonkeyRuntimeTests/Fixtures/FunctionalEval/extract-audio/inputs/clip.mp4")
        #expect(FileManager.default.fileExists(atPath: fixture.path), "fixture video missing")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reframe-e2e-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let binary = tmp.appendingPathComponent("reframe")
        let outVideo = tmp.appendingPathComponent("out.mp4")

        // Build the CLI exactly like the bundling script (two source files, swiftc -O).
        let build = Self.run(URL(fileURLWithPath: "/usr/bin/xcrun"),
                             ["swiftc", "-O", mainSwift.path, plannerSwift.path, "-o", binary.path])
        #expect(build.code == 0, "reframe build failed: \(build.err)")
        #expect(FileManager.default.fileExists(atPath: binary.path), "reframe binary not produced")

        // Run it on the real fixture (smaller height keeps the export quick).
        let runResult = Self.run(binary, ["--input", fixture.path, "--output", outVideo.path, "--aspect", "9:16", "--height", "640"])
        #expect(runResult.code == 0, "reframe run failed: \(runResult.err)")
        #expect(FileManager.default.fileExists(atPath: outVideo.path), "output video not produced")

        // Verify the PRODUCED file is a real vertical 9:16 video that kept its audio and duration.
        let asset = AVURLAsset(url: outVideo)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(vTracks.count == 1)
        let size = try await vTracks[0].load(.naturalSize)
        #expect(Int(size.width) == 360 && Int(size.height) == 640, "expected 360x640, got \(size)")
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(aTracks.count == 1, "audio track was not retained")
        let inDur = try await AVURLAsset(url: fixture).load(.duration).seconds
        let outDur = try await asset.load(.duration).seconds
        #expect(abs(outDur - inDur) < 0.3, "duration drift: in \(inDur) vs out \(outDur)")
    }
}

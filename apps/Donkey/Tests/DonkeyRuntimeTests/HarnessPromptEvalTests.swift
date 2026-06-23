import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

/// Live prompt/planner evals: real model, stubbed system + UI, asserting on the plan the model produces.
/// Opt-in (see `HarnessEvalRunner.configFromEnvironment`); a plain `swift test` returns early. Each test is
/// a scenario — add more by following the same shape.
@Suite
@MainActor
struct HarnessPromptEvalTests {
    @Test
    func clipsYouTubeAndOverlaysAKoreanTranslation() async {
        guard let config = HarnessEvalRunner.configFromEnvironment() else { return }

        let scenario = HarnessEvalScenario(
            name: "korean-clip-overlay",
            prompt: """
            create a 1min clip of this and overlay the korean translation onto the video
            https://www.youtube.com/watch?v=v8u_7PPEzZE. start at the 15min point
            """,
            frontmostApp: "Safari"
        ) { call in
            // Data stubs: hand the model believable results so it walks the whole download → translate →
            // burn-in flow without touching the network or disk.
            if call.name == "llm.generate" {
                return .ok("Wrote subs.srt (Korean subtitles with timestamps).", facts: ["subs.srt": "exists"])
            }
            guard call.name == "shell_exec", let command = call.input["command"] else { return nil }
            if command.contains("yt-dlp") {
                return .ok("[download] 100% — clip.mp4 written (00:01:00, 1920x1080).", facts: ["clip.mp4": "exists"])
            }
            if command.contains("ffprobe") {
                return .ok("duration=60.000000\nformat_name=mov,mp4,m4a,3gp,3g2,mj2")
            }
            if command.contains("ffmpeg"), command.range(of: "subtitles", options: .caseInsensitive) != nil {
                return .ok("out.mp4 written with burned-in Korean subtitles.", facts: ["out.mp4": "exists"])
            }
            if command.contains("ffmpeg") {
                return .ok("ffmpeg: wrote output.")
            }
            return nil
        }

        let run = await HarnessEvalRunner.run(scenario, config: config)
        print("\n=== eval: \(scenario.name) (final: \(String(describing: run.finalStatus))) ===\n\(run.transcript)\n")

        // It is an action turn, and the plan downloads with yt-dlp and burns subtitles in with ffmpeg.
        #expect(run.understanding?.turnKind == .act)
        #expect(run.anyShellMatches("yt-dlp"), "expected a yt-dlp download; shell calls: \(run.shellCommands)")
        #expect(
            run.anyShellMatches("ffmpeg", "subtitles"),
            "expected an ffmpeg subtitle burn-in; shell calls: \(run.shellCommands)"
        )
        // The translation comes from the model (llm.generate) or from yt-dlp's own subtitle download.
        #expect(
            run.used("llm.generate") || run.anyShellMatches("yt-dlp", "sub"),
            "expected a translation/transcription step; tools: \(run.toolNames)"
        )
    }

    @Test
    func fillsF1120FromADataFile() async {
        guard let config = HarnessEvalRunner.configFromEnvironment() else { return }

        let scenario = HarnessEvalScenario(
            name: "fill-f1120-pdf",
            prompt: "fill out f1120.pdf using 1120data.txt",
            frontmostApp: "Finder"
        ) { call in
            // Data stubs: describe the form and the data so the model can plan the fill without real files.
            if call.name == "files.describe" {
                return .ok(
                    "f1120.pdf — AcroForm PDF, 6 pages, 48 fillable fields (text and checkbox). "
                        + "1120data.txt — UTF-8 text, 32 `key: value` lines."
                )
            }
            guard call.name == "shell_exec", let command = call.input["command"] else { return nil }
            // Discovery: the model usually locates the named files first. Tell it where they are so it can
            // proceed to read + fill, instead of repeating the search.
            if command.contains("find ") || command.hasPrefix("ls") || command.contains("mdfind") {
                return .ok("./f1120.pdf\n./1120data.txt", facts: ["found": "f1120.pdf,1120data.txt"])
            }
            if command.contains("1120data.txt"), command.range(of: "cat|head|lit|read", options: .regularExpression) != nil {
                return .ok("name: ACME Corp\nein: 12-3456789\ntax_year: 2025\ntotal_income: 1000000")
            }
            if command.contains("pdf-fill"), command.range(of: "describe|fields|--read|inspect", options: .regularExpression) != nil {
                return .ok(#"{"type":"acroform","fields":[{"name":"f1_01","type":"text"},{"name":"c1_1","type":"checkbox"}]}"#)
            }
            if command.contains("pdf-fill") {
                return .ok("Wrote f1120-filled.pdf (48 fields set).", facts: ["f1120-filled.pdf": "exists"])
            }
            return nil
        }

        let run = await HarnessEvalRunner.run(scenario, config: config)
        print("\n=== eval: \(scenario.name) (final: \(String(describing: run.finalStatus))) ===\n\(run.transcript)\n")

        #expect(run.understanding?.turnKind == .act)
        // It reads the source data (cat/inspect the txt or describe it) before filling.
        #expect(
            run.used("files.describe") || run.shellCommands.contains { $0.contains("1120data.txt") },
            "expected it to read the data file; shell calls: \(run.shellCommands)"
        )
        // It fills with the bundled form tool, not by driving a PDF GUI.
        #expect(
            run.anyShellMatches("pdf-fill") || run.anyShellMatches("lit"),
            "expected a pdf-fill/lit fill step; shell calls: \(run.shellCommands)"
        )
    }
}

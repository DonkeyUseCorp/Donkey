import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// LIVE end-to-end run of "Create a playlist of the 10 best songs from 2000" — the real harness
/// runtime, the real tool registry, the real MusicKit-backed music tools against the real Apple
/// Music API, and the real thread transcript. The one substituted piece is the hosted LLM planner:
/// a scripted planner issues exactly the calls the music skill prescribes (search each song →
/// create → add → entries → complete), so the run is deterministic and needs no backend login.
///
/// Opt-in via `DONKEY_LIVE_MUSIC_E2E=1` because it:
/// - needs Media & Apple Music consent for the test runner and an Apple Music subscription,
/// - CREATES A REAL PLAYLIST in the signed-in library, and Apple provides no delete API — clean
///   up by hand in the Music app afterwards (the name carries a timestamp to spot it).
///
/// Run: `DONKEY_LIVE_MUSIC_E2E=1 DEVELOPER_DIR=/Applications/Xcode.app swift test --filter MusicPlaylistLiveE2ETests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DONKEY_LIVE_MUSIC_E2E"] == "1"))
@MainActor
struct MusicPlaylistLiveE2ETests {
    nonisolated static let command = "Create a playlist of the 10 best songs from 2000"

    /// The list the live run settled on (from web research) — known-good catalog hits from 2000.
    nonisolated static let songs: [(title: String, artist: String)] = [
        ("Bye Bye Bye", "NSYNC"),
        ("Oops!... I Did It Again", "Britney Spears"),
        ("The Real Slim Shady", "Eminem"),
        ("Yellow", "Coldplay"),
        ("Kryptonite", "3 Doors Down"),
        ("Beautiful Day", "U2"),
        ("Ms. Jackson", "OutKast"),
        ("One More Time", "Daft Punk"),
        ("It's My Life", "Bon Jovi"),
        ("Say My Name", "Destiny's Child")
    ]

    /// Replays the music skill's documented flow off the task's typed state: tool history decides
    /// the phase, world-model facts carry the created playlist id, and song ids come from the
    /// `song:<id>` lines music.search prints.
    struct ScriptedPlaylistPlanner: HarnessNextStepPlanning {
        let playlistName: String

        func planNextStep(for task: HarnessAgentState, rollingContext: String?) async -> HarnessToolCall? {
            let history = task.toolHistory
            let searches = history.filter { $0.call.name == MusicPlaybackToolProvider.ToolName.search }
            if searches.isEmpty {
                // The skill doctrine's batched form: every song in ONE pipe-separated search.
                let batch = MusicPlaylistLiveE2ETests.songs
                    .map { "\($0.title) \($0.artist)" }
                    .joined(separator: " | ")
                return HarnessToolCall(
                    name: MusicPlaybackToolProvider.ToolName.search,
                    input: ["query": batch, "limit": "1"]
                )
            }
            func ranPlaylistAction(_ action: String) -> Bool {
                history.contains {
                    $0.call.name == MusicPlaybackToolProvider.ToolName.playlist && $0.call.input["action"] == action
                }
            }
            if !ranPlaylistAction("create") {
                return HarnessToolCall(
                    name: MusicPlaybackToolProvider.ToolName.playlist,
                    input: [
                        "action": "create",
                        "name": playlistName,
                        "description": "The 10 best songs from the year 2000 — Donkey live E2E"
                    ]
                )
            }
            guard let playlistID = task.worldModel.facts["music.playlist.created.id"] else {
                return HarnessToolCall(name: "run.failSafe", input: ["reason": "noCreatedPlaylistID"])
            }
            if !ranPlaylistAction("add") {
                let songIDs = searches.flatMap { Self.songIDs(in: $0.summary) }
                return HarnessToolCall(
                    name: MusicPlaybackToolProvider.ToolName.playlist,
                    input: ["action": "add", "playlistID": playlistID, "songIDs": songIDs.joined(separator: ",")]
                )
            }
            if !ranPlaylistAction("entries") {
                return HarnessToolCall(
                    name: MusicPlaybackToolProvider.ToolName.playlist,
                    input: ["action": "entries", "playlistID": playlistID, "limit": "25"]
                )
            }
            return HarnessToolCall(name: "run.complete", input: ["reason": "Playlist created, filled, and read back"])
        }

        /// Every id from the `song:<id> — title (artist)` lines of a music.search summary — a
        /// batched search reports one hit section per query.
        static func songIDs(in summary: String) -> [String] {
            summary.split(separator: "\n")
                .filter { $0.hasPrefix("song:") }
                .compactMap { $0.dropFirst("song:".count).split(separator: " ").first.map(String.init) }
        }
    }

    @Test
    func createsTheBestOf2000PlaylistForReal() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        // Timestamped so reruns never collide — also keeps createPlaylist's confirm-by-name
        // verification read unambiguous, and makes the playlist easy to find for manual cleanup.
        let playlistName = "Best of 2000 (Donkey E2E \(stamp))"

        let coordinator = HarnessAgentCoordinator()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        let provider = MusicPlaybackToolProvider(service: MusicKitPlaybackService())
        for tool in provider.makeTools() {
            await registry.register(tool)
        }
        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        let task = await coordinator.createAgent(
            id: "live-music-e2e-\(stamp)",
            conversationID: "t",
            goal: Self.command,
            grantedPermissions: [.lifecycle]
        )

        // The same transcript wiring the real route uses, written under a temp root so the run
        // leaves a readable conversation.md to inspect.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-live-music-e2e-\(stamp)", isDirectory: true)
        let transcript = ConversationTranscript(id: task.id, root: root)
        transcript.begin(id: task.id, app: "Music")
        transcript.userMessage(Self.command)
        transcript.planning(
            goal: Self.command,
            targetApp: "Music",
            parameters: ["year": "2000", "count": "10", "playlistName": playlistName],
            successCriteria: "A library playlist named \"\(playlistName)\" exists and lists the 10 songs"
        )

        let steps = await runtime.run(agentID: task.id, planner: ScriptedPlaylistPlanner(playlistName: playlistName)) { step in
            guard let result = step.toolResult else { return }
            transcript.step(
                number: step.task.toolHistory.count,
                thought: nil,
                narration: nil,
                tool: result.toolName,
                input: step.task.toolHistory.last?.call.input ?? [:],
                status: result.status.rawValue,
                output: result.summary
            )
        }

        let finalTask = await coordinator.agent(id: task.id)
        let threadText = (try? String(contentsOfFile: transcript.conversationPath, encoding: .utf8)) ?? ""
        print("Live E2E conversation (\(transcript.conversationPath)):\n\(threadText)")

        // The run completed end to end: one batched search + create + add + entries + run.complete.
        #expect(
            finalTask?.status == .completed,
            "final status \(finalTask?.status.rawValue ?? "nil") — last step: \(steps.last?.toolResult?.summary ?? "none")"
        )
        #expect(steps.count == 5)

        // The real-world outcome, read back from the Apple Music API: the playlist lists the songs.
        let entriesSummary = steps
            .first { $0.toolResult?.toolName == MusicPlaybackToolProvider.ToolName.playlist
                && $0.toolResult?.metadata["reason"] == "entries" }?
            .toolResult?.summary ?? ""
        #expect(entriesSummary.contains("entries (10)"), "entries read-back: \(entriesSummary)")
        #expect(entriesSummary.contains("Bye Bye Bye"))
        #expect(entriesSummary.contains("Say My Name"))

        // And the thread reads as the grouped trace: planning block, step blocks, real outputs.
        #expect(threadText.contains("🗺️ assistant · planning"))
        #expect(threadText.contains("**Goal:** \(Self.command)"))
        #expect(threadText.contains("## Step 1"))
        #expect(threadText.contains("## Step 5"))
        #expect(threadText.contains("**Action:** `music.playlist`"))
        #expect(threadText.contains("### 📄 Output — `succeeded`"))
    }
}

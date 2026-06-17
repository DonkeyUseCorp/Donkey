import Foundation
import Testing
@testable import DonkeyRuntime

@Suite
struct ThreadTranscriptTests {
    @Test
    func stepRendersDecisionThenOutputAsOneBlock() throws {
        let transcript = makeTranscript()
        transcript.step(
            number: 3,
            thought: "Search worked, so now I create the playlist container before adding songs.",
            narration: "Creating the \"Best of 2000\" playlist.",
            tool: "music.playlist",
            input: ["action": "create", "name": "Best of 2000"],
            status: "failed",
            output: "Playlist create call returned no playlist for \"Best of 2000\".",
            planningErrors: ["planning attempt 1/3: chose music.playlist without its required input (action)"]
        )

        let text = try threadText(transcript)
        #expect(text.contains("## Step 3"))
        #expect(text.contains("⚠️ planning attempt 1/3"))
        #expect(text.contains("### 🧠 Decision"))
        #expect(text.contains("**Thought:** Search worked"))
        // The narration is the warm lead line of the block — rendered plainly, not behind a label.
        #expect(text.contains("\nCreating the \"Best of 2000\" playlist.\n"))
        // It leads the decision block, above the fuller thought summary.
        let narrationRange = try #require(text.range(of: "Creating the \"Best of 2000\" playlist."))
        let thoughtRange = try #require(text.range(of: "**Thought:**"))
        #expect(narrationRange.lowerBound < thoughtRange.lowerBound)
        #expect(text.contains("**Action:** `music.playlist`"))
        #expect(text.contains("action: create\nname: Best of 2000"))
        #expect(text.contains("### 📄 Output — `failed`"))
        #expect(text.contains("returned no playlist"))
        let decision = try #require(text.range(of: "### 🧠 Decision"))
        let action = try #require(text.range(of: "**Action:**"))
        let output = try #require(text.range(of: "### 📄 Output"))
        #expect(decision.lowerBound < action.lowerBound)
        #expect(action.lowerBound < output.lowerBound)
    }

    @Test
    func stepOmitsAbsentThoughtAndNarration() throws {
        let transcript = makeTranscript()
        transcript.step(
            number: 1,
            thought: nil,
            narration: "  ",
            tool: "music.status",
            input: [:],
            status: "succeeded",
            output: "Playback state: stopped."
        )

        let text = try threadText(transcript)
        #expect(!text.contains("**Thought:**"))
        // Blank narration is dropped: the decision block goes straight to the action.
        #expect(text.contains("### 🧠 Decision\n\n**Action:** `music.status`"))
        #expect(text.contains("(no input)"))
        #expect(text.contains("### 📄 Output — `succeeded`"))
    }

    @Test
    func planningBlockRendersGoalAppParametersAndCriteria() throws {
        let transcript = makeTranscript()
        transcript.planning(
            goal: "Create a playlist of the 10 best songs from 2000",
            targetApp: "Music",
            parameters: ["year": "2000", "count": "10"],
            successCriteria: "A playlist named \"Best of 2000\" exists with 10 songs",
            clarification: nil
        )

        let text = try threadText(transcript)
        #expect(text.contains("### 🗺️ assistant · planning"))
        #expect(text.contains("**Goal:** Create a playlist of the 10 best songs from 2000"))
        #expect(text.contains("**Target app:** Music"))
        #expect(text.contains("**Parameters:**\n- count: 10\n- year: 2000"))
        #expect(text.contains("**Success criteria:** A playlist named \"Best of 2000\" exists with 10 songs"))
        #expect(!text.contains("**Clarification needed:**"))
    }

    @Test
    func planningBlockOmitsAbsentFieldsAndShowsClarification() throws {
        let transcript = makeTranscript()
        transcript.planning(
            goal: "Send the draft",
            clarification: "Which draft should I send?"
        )

        let text = try threadText(transcript)
        #expect(text.contains("**Goal:** Send the draft"))
        #expect(!text.contains("**Target app:**"))
        #expect(!text.contains("**Parameters:**"))
        #expect(!text.contains("**Success criteria:**"))
        #expect(text.contains("**Clarification needed:** Which draft should I send?"))
    }

    @Test
    func flatEntriesStillRenderAroundSteps() throws {
        let transcript = makeTranscript()
        transcript.begin(id: "T1", app: "Music")
        transcript.userMessage("create a playlist")
        transcript.systemEvent("Run finished: completed after 1 step(s).")
        transcript.error("Run could not start (offline).")
        transcript.response("Done — playlist created.")

        let text = try threadText(transcript)
        #expect(text.contains("# Thread T1"))
        #expect(text.contains("👤 user · message"))
        #expect(text.contains("create a playlist"))
        #expect(text.contains("⚙️ system · event"))
        #expect(text.contains("⚠️ system · error"))
        #expect(text.contains("💬 assistant · response"))
    }

    @Test
    func stepRendersTimingLineWithModalityCacheAndElements() throws {
        let transcript = makeTranscript()
        transcript.step(
            number: 2,
            thought: nil,
            narration: "Reading the screen.",
            tool: "vision.capture",
            input: [:],
            status: "succeeded",
            output: "Captured 31 element(s).",
            decisionMS: 8_400,
            toolMS: 320,
            modality: "vision",
            cacheHit: false,
            elementCount: 31
        )

        let text = try threadText(transcript)
        #expect(text.contains("⏱ decision 8.4s · tool 320ms · 👁️ vision · cache miss · 31 elems"))
    }

    @Test
    func stepOmitsTimingLineWhenNothingIsKnown() throws {
        let transcript = makeTranscript()
        transcript.step(
            number: 1,
            thought: nil,
            narration: nil,
            tool: "shell_exec",
            input: ["command": "ls"],
            status: "succeeded",
            output: "ok"
        )

        let text = try threadText(transcript)
        #expect(!text.contains("⏱"))
    }

    @Test
    func modelCallRendersClippedPromptResponseAndMeta() throws {
        let transcript = makeTranscript()
        transcript.modelCall(
            kindLabel: "planner step",
            prompt: "GOAL: do the thing\nHISTORY: ...",
            response: "{\"tool\":\"ax.observe\",\"input\":{}}",
            finishReason: "STOP",
            attempt: 2,
            durationMS: 1_240,
            status: "ok"
        )

        let text = try threadText(transcript)
        #expect(text.contains("### 🔮 model · planner step"))
        #expect(text.contains("**Duration:** 1.2s"))
        #expect(text.contains("**Attempt:** 2"))
        #expect(text.contains("**Finish:** STOP"))
        #expect(text.contains("**Status:** ok"))
        #expect(text.contains("**Prompt:**"))
        #expect(text.contains("GOAL: do the thing"))
        #expect(text.contains("**Response:**"))
        #expect(text.contains("\"tool\":\"ax.observe\""))
    }

    private func makeTranscript() -> ThreadTranscript {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        return ThreadTranscript(id: UUID().uuidString, root: root)
    }

    private func threadText(_ transcript: ThreadTranscript) throws -> String {
        try String(contentsOfFile: transcript.threadPath, encoding: .utf8)
    }
}

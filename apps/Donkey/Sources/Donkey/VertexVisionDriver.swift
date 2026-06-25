import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Drives an app by vision using `gemini-3.5-flash`'s built-in `computer_use` tool reached directly
/// over Vertex (`GeminiVertexVisionPlanner`). This is the "look at the screen, decide, act" fallback
/// the Live command session escalates to (via `vision_control`) when no fast tool can operate an app.
///
/// The per-turn loop, focus guards, screenshot/retry, and action execution all live in
/// `VisionActionDriver`; this is a thin adapter that supplies the direct-Vertex planner so the Live
/// escalation and the hosted `createResponse` path share one driver.
///
/// IMPORTANT: must NOT be driven from inside the Live session's `for await session.events` consumer
/// task — ScreenCaptureKit `capture` hangs there. Run it from a separate task (see
/// `GeminiLiveVoiceController`).
@MainActor
enum VertexVisionDriver {
    struct Outcome: Sendable {
        var completed: Bool
        var turns: Int
        var history: [String]
    }

    static func drive(
        appName: String,
        bundleIdentifier: String?,
        goal: String,
        auth: GeminiVertexVisionPlanner.VertexAuth,
        model: String,
        settleNanoseconds: UInt64 = 1_500_000_000,
        maxTurns: Int = 16,
        capturer: ScreenCaptureKitWindowScreenshotCapturer = ScreenCaptureKitWindowScreenshotCapturer(),
        verify: (@MainActor () -> Bool)? = nil
    ) async -> Outcome {
        // Per-app operating knowledge comes from a discoverable skill pack (a BuiltInSkills/<app>/SKILL.md
        // with an `apps:` line), never a hardcoded app list — same source the hosted vision path uses.
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(
            forApp: appName, bundleIdentifier: bundleIdentifier
        )

        let outcome = await VisionActionDriver.drive(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            goal: goal,
            appGuidance: appGuidance,
            maxTurns: maxTurns,
            settleNanoseconds: settleNanoseconds,
            capture: { try await capturer.capture(target: $0) },
            verify: verify,
            onTurn: nil,
            planner: { goal, app, shot, window, history, guidance in
                try await GeminiVertexVisionPlanner.nextAction(
                    auth: auth,
                    model: model,
                    goal: goal,
                    appName: app,
                    history: history,
                    appGuidance: guidance,
                    compressed: ScreenshotCompression.compressedForModel(shot),
                    window: window
                )
            }
        )

        return Outcome(completed: outcome.completed, turns: outcome.turns, history: outcome.history)
    }
}

import DonkeyContracts
import DonkeyHarness

/// Which tools the planner is OFFERED for a turn, derived from the STRUCTURED understanding — never from the
/// raw command text. The full catalog (~39 tools) is rendered into the cacheable prompt slot on every step,
/// so trimming it to what the turn can actually use is the cheapest way to cut per-call input tokens.
///
/// Conservative by construction: when the turn might drive a GUI — or no understanding was produced, which
/// defaults `actionSurface` to `.guiApp` — the whole catalog stays. Only an app-less turn (the deliverable is
/// a file, an answer, or a system change) drops the app-driving clusters it can never reach for. SEE/act
/// tools are deliberately kept so an app-less step that unexpectedly needs the screen can still look.
public enum PlannerToolScope {
    /// Tools that only make sense while driving an app's interface: the AppleScript generate→validate→execute
    /// pipeline (drives a target app), the app-learning workflow (explores an app's GUI to distill a skill),
    /// and the cursor-path visualizer. An app-less turn reaches none of them — system work goes through
    /// `shell_exec`, not these — so offering them is pure input-token weight on every step.
    static let guiOnlyToolNames: Set<String> = [
        "automation.applescript.generate",
        "automation.applescript.validate",
        "automation.applescript.execute",
        "application.learning.start",
        "application.learning.captureState",
        "application.learning.proposeExploration",
        "application.learning.distill",
        "application.learning.saveSkillPack",
        "agent.path.visualize"
    ]

    /// Filter the catalog for a turn. Returns the descriptors unchanged unless the turn is app-less, in which
    /// case the GUI-only clusters are dropped.
    public static func scoped(
        _ descriptors: [HarnessToolDescriptor],
        actionSurface: HarnessActionSurface?
    ) -> [HarnessToolDescriptor] {
        guard actionSurface == .appless else { return descriptors }
        return descriptors.filter { !guiOnlyToolNames.contains($0.name) }
    }
}

import DonkeyContracts
import Testing
@testable import DonkeyAI
@testable import DonkeyHarness

/// The planner is offered fewer tools on an app-less turn, trimming per-call input tokens, while a turn that
/// might drive a GUI (or an unknown one) still sees the whole catalog.
@Suite
struct PlannerToolScopeTests {
    private var catalog: [HarnessToolDescriptor] { BuiltInHarnessToolCatalog.descriptors }

    @Test
    func applessDropsGuiOnlyClustersButKeepsCapabilities() {
        let scoped = PlannerToolScope.scoped(catalog, actionSurface: .appless)
        let names = Set(scoped.map(\.name))
        // GUI-driving clusters an app-less turn can never reach for are gone.
        #expect(!names.contains("automation.applescript.execute"))
        #expect(!names.contains("application.learning.start"))
        #expect(!names.contains("agent.path.visualize"))
        // Capability and reasoning tools an app-less turn still needs stay.
        #expect(names.contains("transcribe"))
        #expect(names.contains("shorts.make"))
        #expect(names.contains("llm.generate"))
        #expect(scoped.count < catalog.count)
    }

    @Test
    func guiAppKeepsTheWholeCatalog() {
        #expect(PlannerToolScope.scoped(catalog, actionSurface: .guiApp).count == catalog.count)
    }

    @Test
    func missingUnderstandingKeepsTheWholeCatalog() {
        #expect(PlannerToolScope.scoped(catalog, actionSurface: nil).count == catalog.count)
    }
}

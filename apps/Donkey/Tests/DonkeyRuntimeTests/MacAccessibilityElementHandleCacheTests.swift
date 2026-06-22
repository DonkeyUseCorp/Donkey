@preconcurrency import ApplicationServices
@testable import DonkeyRuntime
import Testing

/// The handle cache anchors actions to the live control observed for a node. These cover the contract
/// the action backend relies on: round-trip lookup, wholesale replacement per observe, and per-process
/// isolation. A real (cheap) `AXUIElement` for the test process stands in for an observed control.
@MainActor
@Suite
struct MacAccessibilityElementHandleCacheTests {
    @Test
    func storesAndLooksUpHandlesByNode() {
        let cache = MacAccessibilityElementHandleCache.shared
        let pid = getpid()
        cache.clear(processID: pid)

        cache.replace(processID: pid, handles: ["ax-1.2": AXUIElementCreateApplication(pid)])
        #expect(cache.handle(processID: pid, nodeID: "ax-1.2") != nil)
        #expect(cache.handle(processID: pid, nodeID: "ax-9.9") == nil)

        cache.clear(processID: pid)
    }

    @Test
    func replaceEvictsThePriorSnapshot() {
        let cache = MacAccessibilityElementHandleCache.shared
        let pid = getpid()
        let element = AXUIElementCreateApplication(pid)

        cache.replace(processID: pid, handles: ["old": element])
        cache.replace(processID: pid, handles: ["new": element])
        #expect(cache.handle(processID: pid, nodeID: "old") == nil)
        #expect(cache.handle(processID: pid, nodeID: "new") != nil)

        cache.clear(processID: pid)
    }

    @Test
    func processesDoNotShareHandles() {
        let cache = MacAccessibilityElementHandleCache.shared
        let pidA = getpid()
        let pidB = pidA &+ 1
        cache.clear(processID: pidB)

        cache.replace(processID: pidA, handles: ["a": AXUIElementCreateApplication(pidA)])
        #expect(cache.handle(processID: pidB, nodeID: "a") == nil)
        #expect(cache.handle(processID: pidA, nodeID: "a") != nil)

        cache.clear(processID: pidA)
    }
}

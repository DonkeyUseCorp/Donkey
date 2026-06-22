import DonkeyContracts
import DonkeyHarness
import Foundation

/// Claude-style rolling compaction for a single conversation. Each step it builds the bounded context
/// the planner carries (recent events plus the last summaries); when that context grows past the policy
/// threshold it summarizes the older turns into a fresh summary event written back into the conversation,
/// so later steps read the digest instead of the raw history. The full on-disk record is never modified —
/// only the structured store gains a summary event.
struct ConversationCompactionDriver: HarnessConversationCompacting {
    let conversationStore: any HarnessConversationStoring
    let coordinator: HarnessAgentCoordinator
    let compactor: HarnessConversationCompactor
    /// Wraps the hosted text generator so the driver stays free of inference wiring.
    let generate: @Sendable (String) async -> String?

    func rollingContext(agentID: String) async -> String? {
        guard let agent = await coordinator.agent(id: agentID) else { return nil }
        let conversationID = agent.conversationID
        var events = await conversationStore.events(conversationID: conversationID)
        guard !events.isEmpty else { return nil }

        let assets = await conversationStore.assets(conversationID: conversationID)
        let conversation = await conversationStore.conversation(id: conversationID)
            ?? HarnessConversation(id: conversationID, title: agent.goal)
        let activeAgents = await coordinator.activeAgents().filter { $0.conversationID == conversationID }

        let policy = compactor.policy
        var compacted = compactor.compact(
            conversation: conversation,
            currentTurn: nil,
            events: events,
            assets: assets,
            activeAgents: activeAgents
        )

        // Over the threshold: fold the older turns into a new summary event, then recompute so this step
        // already carries the digest. Sort once here and share it with the debounce and the summarizer.
        if compacted.promptText.count > policy.summaryTriggerCharacters {
            let sortedEvents = events.sorted { $0.sequence < $1.sequence }
            if Self.shouldSummarize(sortedEvents: sortedEvents, policy: policy),
               let summary = await summarizeOlderTurns(sortedEvents: sortedEvents, policy: policy) {
                let nextSequence = (sortedEvents.last?.sequence ?? -1) + 1
                let summaryEvent = HarnessConversationEvent(
                    conversationID: conversationID,
                    role: .summary,
                    text: summary,
                    sequence: nextSequence,
                    metadata: ["compactor": "rolling-summary-v1"]
                )
                await conversationStore.appendEvent(summaryEvent)
                events.append(summaryEvent)
                compacted = compactor.compact(
                    conversation: conversation,
                    currentTurn: nil,
                    events: events,
                    assets: assets,
                    activeAgents: activeAgents
                )
            }
        }

        let text = compacted.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Summarize only the turns about to age out of the recent window — those whose detail the next
    /// prompt would otherwise drop. Returns nil when there is nothing old enough to summarize.
    private func summarizeOlderTurns(
        sortedEvents: [HarnessConversationEvent],
        policy: HarnessCompactionPolicy
    ) async -> String? {
        let older = sortedEvents.dropLast(policy.maxEvents)
        guard !older.isEmpty else { return nil }
        let body = older
            .map { "[\($0.sequence)] \($0.role.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let prompt = """
        Summarize the earlier part of this conversation into a compact running brief the assistant can \
        rely on to stay coherent across later turns. Capture the goal, what has happened, key decisions, \
        and any open threads. Be concrete and short.

        EARLIER CONVERSATION:
        \(body)
        """
        guard let summary = await generate(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return "Summary of earlier turns:\n\(summary)"
    }

    /// Debounce: summarize only when enough new events have arrived since the last summary, so the loop
    /// does not re-summarize every step once it is hovering near the trigger. Always allowed the first time.
    private static func shouldSummarize(
        sortedEvents: [HarnessConversationEvent],
        policy: HarnessCompactionPolicy
    ) -> Bool {
        guard let newest = sortedEvents.last?.sequence else { return false }
        guard let lastSummary = sortedEvents.last(where: { $0.role == .summary })?.sequence else { return true }
        return (newest - lastSummary) >= policy.minEventsBetweenSummaries
    }
}

// The chat harness's understanding boundary for one composer turn: a fast
// structured model call judges whether the newest user message asks the
// assistant for anything, and the harness gates deterministically on the
// verdict. A "chat" turn (greeting, thanks — social filler that requests
// nothing) runs with no tool declarations at all, so unsolicited edits are
// impossible by construction rather than discouraged by prompt.

export type TurnIntent = "work" | "chat";

export const TURN_INTENT_PROMPT = `You gate the tools of an AI assistant built into a video editor. Read the conversation and judge only its newest user message: does it ask the assistant for anything — an edit, an answer, media, information, an opinion, or any other work — or is it pure social filler (a greeting, thanks, a sign-off, an acknowledgement) that requests nothing?

Terse follow-ups ("yes", "do it", "the second one") refer to the earlier turns and DO ask for something.

Reply with exactly one word:
work — the message asks for something, however vague or implicit.
chat — the message requests nothing.

If unsure, reply work.`;

/** The conversation as plain text turns for the classifier — recent turns ride
 * along so follow-ups keep their referent, and each is capped so a pasted wall
 * of text can't blow the call's budget. */
export function turnIntentInput(
  turns: { role: "user" | "assistant"; text: string }[]
): Record<string, unknown>[] {
  return turns
    .filter((t) => t.text)
    .slice(-6)
    .map((t) => ({ role: t.role, content: [{ text: t.text.slice(0, 2000) }] }));
}

/** Deterministic read of the classifier's one-word verdict; anything but a
 * clear "chat" counts as work, so a garbled reply never blocks a request. */
export function parseTurnIntent(outputText: string | undefined): TurnIntent {
  return /^\W*chat\b/i.test((outputText ?? "").trim()) ? "chat" : "work";
}

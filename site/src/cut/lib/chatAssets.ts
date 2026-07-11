"use client";

import { useEditor } from "./store";

// Chat-created media belongs to its thread. The files live in the project's
// media folder like every other asset (drag-to-timeline and previews need
// that), but each is tagged origin "chat" plus the owning thread id, so it
// shows only on its chat card — and deleting the thread deletes whatever it
// still owns. Assets the user moved on survive: placed on the timeline
// (referenced by a clip), filed into Media (origin cleared), or copied into
// the Library (its own file).

let activeChatId: string | null = null;

/** The chat thread whose tools are currently running. The chat session sets
 * this while mounted so tool-created assets can be tagged with their owner. */
export function setActiveChatThread(id: string | null) {
  activeChatId = id;
}

/** The owning thread to stamp on an asset created right now. Capture it
 * before a background render so the clip files under the chat that asked,
 * even if the user has switched threads by the time it lands. */
export function chatOwner(): string | null {
  return activeChatId;
}

/** Tag a landed project asset as owned by a chat thread. */
export function tagChatAsset(assetId: string, chatId: string | null = activeChatId) {
  if (!chatId) return;
  useEditor.getState().updateAsset(assetId, { origin: "chat", chatId });
}

/** Delete the assets a thread still owns: origin "chat", tagged with the
 * thread, and not referenced by any clip. One undo step. */
export function deleteChatAssets(threadId: string) {
  const s = useEditor.getState();
  const inUse = new Set(
    [...s.clips, ...s.overlayClips, ...s.audioClips].map((c) => c.assetId)
  );
  const owned = s.assets.filter(
    (a) => a.origin === "chat" && a.chatId === threadId && !inUse.has(a.id)
  );
  if (owned.length === 0) return;
  s.beginHistoryBatch();
  for (const a of owned) useEditor.getState().removeAsset(a.id);
  useEditor.getState().endHistoryBatch();
}

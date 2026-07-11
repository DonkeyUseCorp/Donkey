"use client";

import { useGenerate } from "./generate";
import { usePreviewAudio } from "./previewAudio";
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

/** Whether a thread still owns chat media in the open project — such a thread
 * must not fall out of history silently, or its media becomes unreachable. */
export function threadOwnsAssets(threadId: string): boolean {
  return useEditor.getState().assets.some(
    (a) => a.origin === "chat" && a.chatId === threadId
  );
}

/** Delete the assets a thread still owns: origin "chat", tagged with the
 * thread, and not referenced by any clip. Assets sit outside the undo
 * history, so this is not undoable — call it only for an explicit thread
 * deletion. */
export function deleteChatAssets(threadId: string) {
  const s = useEditor.getState();
  const inUse = new Set(
    [...s.clips, ...s.overlayClips, ...s.audioClips].map((c) => c.assetId)
  );
  const owned = s.assets.filter(
    (a) => a.origin === "chat" && a.chatId === threadId && !inUse.has(a.id)
  );
  for (const a of owned) {
    usePreviewAudio.getState().stop(a.url);
    useEditor.getState().removeAsset(a.id);
    // A render-history entry pointing at deleted media would show as a dead
    // row in the Video panel; it goes with the asset.
    for (const j of useGenerate.getState().jobs.filter((job) => job.assetId === a.id)) {
      useGenerate.getState().dismiss(j.id);
    }
  }
}

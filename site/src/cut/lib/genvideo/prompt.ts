/**
 * One prompt builder, so every generation call is consistent.
 *
 * Text describes what happens; references (character and location images, plus
 * whatever the user brought) carry what things look like and are passed as
 * media, never described here. Keeping that split clean is what holds identity
 * and style continuous across shots.
 */

import type { RefAsset, Shot, VideoAsset, VideoProject } from "./types";

/** The text half of a shot's generation prompt. */
export function buildPrompt(shot: Shot, project: VideoProject): string {
  const parts = [shot.action.trim()];
  // The narration grounds what the shot depicts, phrased as off-screen audio —
  // a bare quote reads as a caption request and the model burns the words into
  // the picture as speech bubbles and subtitle bars.
  const spoken = (shot.dialogue ?? shot.audioText).trim();
  if (spoken) parts.push(`The voiceover heard over this shot (audio only, never visible): ${spoken}`);
  const location = findAsset(project.locations, shot.location);
  if (location) parts.push(`Setting, ${location.name}.`);
  else if (shot.location) parts.push(`Setting, ${shot.location}.`);
  if (shot.framing) parts.push(`Framing, ${shot.framing}.`);
  if (project.style) parts.push(project.style);
  parts.push(
    "One single continuous shot with fluid, continuous character motion throughout — smooth, natural movement, never held poses or stepped animation. Pure visual storytelling: no on-screen text of any kind — no captions, subtitles, speech bubbles, titles, signs, or lettering — and no split screens, panels, or storyboard collages. No baked-in editing effects: no transition frames, fades, motion-blur smears, borders, or blurred letterbox bands — the picture fills the frame edge to edge; cuts and transitions are added later in the editor."
  );
  return parts.filter(Boolean).join(" ").trim();
}

/** The reference media a shot's generation draws from: its characters, its
 * location, and every reference the user brought (identity, style, motion). */
export function shotRefs(shot: Shot, project: VideoProject): RefAsset[] {
  const refs: RefAsset[] = [];
  for (const id of shot.characters) {
    const asset = findAsset(project.characters, id);
    if (asset?.mediaId) refs.push({ mediaId: asset.mediaId, kind: "image", purpose: "character", name: asset.name });
  }
  const location = findAsset(project.locations, shot.location);
  if (location?.mediaId) refs.push({ mediaId: location.mediaId, kind: "image", purpose: "location", name: location.name });
  refs.push(...project.references);
  return refs;
}

/** The prompt that mints one reference image for a character or location. */
export function buildRefPrompt(asset: VideoAsset, style: string): string {
  const subject =
    asset.kind === "character"
      ? `Character reference: ${asset.name}. ${asset.description}`
      : `Location reference: ${asset.name}. ${asset.description}`;
  return [subject, style].filter(Boolean).join(" ").trim();
}

/** The user references that anchor a character/location reference image. */
export function refsForAsset(asset: VideoAsset, project: VideoProject): RefAsset[] {
  const want = asset.kind === "character" ? "character" : "location";
  return project.references.filter((r) => r.purpose === want || r.purpose === "style");
}

function findAsset(list: VideoAsset[], id: string): VideoAsset | undefined {
  if (!id) return undefined;
  return list.find((a) => a.id === id);
}

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
  const location = findAsset(project.locations, shot.location);
  if (location) parts.push(`Setting, ${location.name}.`);
  else if (shot.location) parts.push(`Setting, ${shot.location}.`);
  if (shot.framing) parts.push(`Framing, ${shot.framing}.`);
  if (project.style) parts.push(project.style);
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

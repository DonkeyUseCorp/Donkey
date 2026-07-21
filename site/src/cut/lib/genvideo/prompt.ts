/**
 * One prompt builder, so every generation call is consistent.
 *
 * Text describes what happens; references (character and location images, plus
 * whatever the user brought) carry what things look like and are passed as
 * media. That split holds whenever an image can ride — prose that fights the
 * reference pixels weakens them. When one can't (a sheet that never minted, a
 * ladder rung that takes no images), the bible's fixed description rides in
 * the text instead — the same words every shot, because on that call they are
 * the only thing holding identity.
 */

import type { RefAsset, Shot, VideoAsset, VideoProject } from "./types";

const sentence = (s: string) => (/[.!?]$/.test(s.trim()) ? s.trim() : `${s.trim()}.`);

/** The text half of a shot's generation prompt. */
export function buildPrompt(shot: Shot, project: VideoProject): string {
  // The look leads: video models weight the prompt's head, and the wrong
  // medium (live-action in an animated cut) is the costliest way a render
  // can miss.
  const parts = [project.style, shot.action.trim()];
  // The narration grounds what the shot depicts, phrased as off-screen audio —
  // a bare quote reads as a caption request and the model burns the words into
  // the picture as speech bubbles and subtitle bars.
  const spoken = (shot.dialogue ?? shot.audioText).trim();
  if (spoken) parts.push(`The voiceover heard over this shot (audio only, never visible): ${spoken}`);
  const location = findAsset(project.locations, shot.location);
  if (location) parts.push(`Setting, ${location.name}.`);
  else if (shot.location) parts.push(`Setting, ${shot.location}.`);
  // Cast or setting with no minted sheet can never ride as an image on any
  // call — the bible's wording is all that holds their identity, so it rides
  // here, in every render of the shot.
  if (location && !location.mediaId) parts.push(sentence(location.description));
  for (const id of shot.characters) {
    const asset = findAsset(project.characters, id);
    if (asset && !asset.mediaId) parts.push(sentence(`${asset.name}: ${asset.description}`));
  }
  if (shot.framing) parts.push(`Framing, ${shot.framing}.`);
  // The beat's job in the story, phrased as direction — it steers the
  // composition and motion toward what the shot is FOR, and rides late so it
  // never outweighs the look or the action at the prompt's head.
  if (shot.intent) parts.push(`This shot's role in the story: ${sentence(shot.intent)}`);
  parts.push(
    "One single continuous shot with fluid, continuous character motion throughout — smooth, natural movement, never held poses or stepped animation. Pure visual storytelling: no on-screen text of any kind — no captions, subtitles, speech bubbles, titles, signs, or lettering — and no split screens, panels, or storyboard collages. No baked-in editing effects: no transition frames, fades, motion-blur smears, borders, or blurred letterbox bands — the picture fills the frame edge to edge, composed upright for this frame with a level horizon; cuts and transitions are added later in the editor."
  );
  return parts.filter(Boolean).join(" ").trim();
}

/** The run's technique anchor: the first minted sheet. Every later sheet and
 * keyframe renders with it riding as a style reference, so one drawing
 * technique propagates through the whole run instead of each render
 * converging on its own lineweight, shading, and palette. */
export function styleAnchor(project: VideoProject): RefAsset | undefined {
  const minted = [...project.characters, ...project.locations].find((a) => a.mediaId);
  return minted?.mediaId
    ? { mediaId: minted.mediaId, kind: "image", purpose: "style", name: minted.name }
    : undefined;
}

/** The reference media a shot's generation draws from: its characters, its
 * location, the run's technique anchor, and every reference the user brought
 * (identity, style, motion). */
export function shotRefs(shot: Shot, project: VideoProject): RefAsset[] {
  const refs: RefAsset[] = [];
  for (const id of shot.characters) {
    const asset = findAsset(project.characters, id);
    if (asset?.mediaId)
      refs.push({ mediaId: asset.mediaId, kind: "image", purpose: "character", name: asset.name, description: asset.description });
  }
  const location = findAsset(project.locations, shot.location);
  if (location?.mediaId)
    refs.push({ mediaId: location.mediaId, kind: "image", purpose: "location", name: location.name, description: location.description });
  const anchor = styleAnchor(project);
  if (anchor && !refs.some((r) => r.mediaId === anchor.mediaId)) refs.push(anchor);
  refs.push(...project.references);
  return refs;
}

/** The role of every reference riding an IMAGE render, stated in its prompt.
 * The image model receives references as bare pixels; without this text it
 * guesses — and the commonest wrong guess is pasting a style reference's
 * subjects into the shot. Cast sheets fix appearance; style references
 * contribute technique only. */
export function refRoleNote(refs: RefAsset[]): string {
  const cast = refs
    .filter((r) => r.purpose === "character" || r.purpose === "location")
    .map((r) => r.name)
    .filter(Boolean);
  const styled = refs.some((r) => r.purpose === "style");
  const parts: string[] = [];
  if (cast.length)
    parts.push(`The attached pictures of ${cast.join(", ")} fix exactly how they look — same face, wardrobe, and build.`);
  if (styled)
    parts.push(
      "The style reference images set the drawing technique: draw as the same artist — identical linework, shading, finish, and the exact same colors (a garment's yellow stays that yellow, sampled from the reference, never a nearby shade). The people, characters, and objects pictured in them stay out of the frame unless this prompt names them."
    );
  return parts.join(" ");
}

/** What no render may show, whatever the look: the frame-integrity bans the
 * prompt states affirmatively, restated as the model's negative prompt. */
const BASE_NEGATIVE =
  "on-screen text, captions, subtitles, watermarks, letterboxing, black bars, split screen, storyboard panels, sideways or rotated composition";

/** The negative prompt a shot renders with: the base bans plus the style
 * bible's banned tells for this look (project.negative). */
export function buildNegative(project: VideoProject): string {
  return [BASE_NEGATIVE, project.negative].filter(Boolean).join(", ");
}

/** Fold the written identity of unanchored cast into one render's prompt.
 * `riding` is the mediaIds that actually ride this call as images; every
 * character/location ref outside it gets its bible description appended —
 * the same fixed words every shot, so text-only renders drift around one
 * written identity instead of a bare action line. */
export function describeUnanchored(
  prompt: string,
  refs: RefAsset[],
  riding: ReadonlySet<string>
): string {
  const lines = refs
    .filter(
      (r) =>
        (r.purpose === "character" || r.purpose === "location") &&
        r.description &&
        !riding.has(r.mediaId)
    )
    .map((r) => sentence(r.name ? `${r.name}: ${r.description}` : r.description ?? ""));
  return lines.length ? `${prompt} ${lines.join(" ")}` : prompt;
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

/**
 * How a generated clip fills its exact timeline slot — the editor-boundary twin
 * of the frame coverage invariant. A slot is [start, end) seconds on the track;
 * a shot must occupy exactly that, or the track opens a black gap between shots.
 *
 * - An image has no intrinsic length, so it simply takes the slot.
 * - A video longer than the slot trims its tail.
 * - A shorter video time-stretches to fill (speed < 1), floored at speedMin.
 *   Below that floor — a source under `speedMin × slot` — the clip is as slow as
 *   allowed and a small gap remains, which beats a frozen crawl.
 *
 * A clip's footprint is (out − in) / (speed ?? 1); this returns `out` (with
 * in = 0) and an optional `speed`, so footprint equals the slot in every case
 * except the sub-floor one. Pure and dependency-free so the self-test can assert
 * the tiling without a browser store.
 */
export function fillSlot(
  kind: "video" | "image",
  srcDuration: number,
  slotSec: number,
  speedMin: number
): { out: number; speed?: number } {
  const slot = Math.max(0.1, slotSec);
  if (kind === "image") return { out: slot };
  const src = Math.max(0.1, srcDuration);
  if (src >= slot) return { out: slot };
  return { out: src, speed: Math.max(speedMin, src / slot) };
}

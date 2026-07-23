"use client";

/**
 * The live preview <canvas>, registered by Preview while it is mounted, so
 * panels can sample the composited frame (the color panel's histogram reads
 * it). Media decoders load with crossOrigin=anonymous and the engine serves
 * CORS, so the canvas stays readable.
 */
let el: HTMLCanvasElement | null = null;

export function setPreviewCanvas(canvas: HTMLCanvasElement | null) {
  el = canvas;
}

export function getPreviewCanvas(): HTMLCanvasElement | null {
  return el;
}

/**
 * A clip's raw decoded frame, straight from the playback engine's decoder
 * element — before any color grade — so analysis (the color panel's Auto)
 * never fits corrections on top of its own output. The engine registers the
 * sampler while mounted; null when the clip has no ready decoder.
 */
type SourceSampler = (clipId: string) => CanvasImageSource | null;
let sampler: SourceSampler | null = null;

export function registerSourceSampler(fn: SourceSampler | null) {
  sampler = fn;
}

export function sampleClipSource(clipId: string): CanvasImageSource | null {
  return sampler?.(clipId) ?? null;
}

/** A small RGBA readout of the clip's raw frame, for analysis (auto grade);
 * null when no decoder is ready or the pixels are unreadable. */
export function sampleClipFrameData(clipId: string, w = 96, h = 54): Uint8ClampedArray | null {
  const src = sampleClipSource(clipId);
  if (!src) return null;
  const scratch = document.createElement("canvas");
  scratch.width = w;
  scratch.height = h;
  const ctx = scratch.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;
  try {
    ctx.drawImage(src, 0, 0, w, h);
    return ctx.getImageData(0, 0, w, h).data;
  } catch {
    return null;
  }
}

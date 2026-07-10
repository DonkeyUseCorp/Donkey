"use client";

import type { AssetRef } from "./assetRef";

// Turn an asset ref into the inline-image shape the hosted generation routes
// take (`inputs.images = [{ data, mimeType }]`). Stock images upload as-is;
// video refs (project clips, library media, generated stills) upload a single
// captured frame — the browser reads the same media URLs the previews use.

export interface InlineImage {
  /** Base64 payload, no data: prefix. */
  data: string;
  mimeType: string;
}

const MAX_W = 1280;
const JPEG_Q = 0.85;

function splitDataUrl(dataUrl: string): InlineImage {
  const comma = dataUrl.indexOf(",");
  // Between "data:" and the first ";" (or "," when there are no params). A
  // typeless data URL ("data:;base64,…", e.g. a fetched blob with no
  // Content-Type) leaves this empty — fall back so the hosted route, which
  // rejects an empty mimeType, still gets a usable image part.
  const header = dataUrl.slice(5, comma);
  const mimeType = header.split(";")[0] || "image/png";
  return { data: dataUrl.slice(comma + 1), mimeType };
}

function blobToInline(blob: Blob): Promise<InlineImage> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(splitDataUrl(String(r.result)));
    r.onerror = () => reject(new Error("Could not read the image."));
    r.readAsDataURL(blob);
  });
}

function captureFrame(url: string, duration?: number): Promise<InlineImage> {
  return new Promise((resolve, reject) => {
    const v = document.createElement("video");
    v.preload = "auto";
    v.muted = true;
    // Media may come from the engine on another origin; anonymous CORS keeps
    // the canvas grab from tainting.
    v.crossOrigin = "anonymous";
    let timer = 0;
    const fail = (msg: string) => {
      clearTimeout(timer);
      v.removeAttribute("src");
      v.load();
      reject(new Error(msg));
    };
    // A seek whose `seeked` never fires (a too-short clip, a source that
    // resolves currentTime synchronously) would hang refsToInlineImages and
    // wedge the whole generation. Bail after a few seconds, like visualFrames.
    timer = window.setTimeout(() => fail("Timed out reading a reference frame."), 4000);
    v.onerror = () => fail("Could not read the video for a reference frame.");
    v.onloadedmetadata = () => {
      // Same poster spot the cards show, so the reference matches the preview.
      v.currentTime = Math.min(1, Math.max(0.1, (duration || v.duration || 2) / 10));
    };
    v.onseeked = () => {
      if (v.readyState < 2 || !v.videoWidth) return fail("The video has no readable frame.");
      const w = Math.min(MAX_W, v.videoWidth);
      const h = Math.round((w / v.videoWidth) * v.videoHeight);
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext("2d");
      if (!ctx) return fail("Could not draw the reference frame.");
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(v, 0, 0, w, h);
      try {
        const out = splitDataUrl(canvas.toDataURL("image/jpeg", JPEG_Q));
        clearTimeout(timer);
        v.removeAttribute("src");
        v.load();
        resolve(out);
      } catch {
        fail("Could not capture a reference frame.");
      }
    };
    v.src = url;
  });
}

/** A single reference image for `ref`: the file itself for images, a captured
 * poster frame for videos. Audio has no picture and rejects. */
export async function refToInlineImage(ref: AssetRef): Promise<InlineImage> {
  if (ref.kind === "audio") {
    throw new Error(`“${ref.name}” is audio — it can't be a visual reference.`);
  }
  if (ref.kind === "image") {
    const res = await fetch(ref.url);
    if (!res.ok) throw new Error(`Could not load “${ref.name}”.`);
    return blobToInline(await res.blob());
  }
  return captureFrame(ref.url, ref.duration);
}

/** Reference images for a whole ref list, in order; skips nothing — a broken
 * ref fails the call so the user knows the reference didn't ride along. */
export function refsToInlineImages(refs: AssetRef[]): Promise<InlineImage[]> {
  return Promise.all(refs.map(refToInlineImage));
}

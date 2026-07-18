"use client";

/**
 * Reference media as inline image parts for hosted-model calls. Resolution
 * goes through findRunAsset so a background run (its project closed) keeps
 * its references; anything unresolvable is skipped, never fatal — a missing
 * reference degrades the call, it doesn't block it.
 *
 * Mime derivation rides refMedia's byte-sniffing path: the engine's media
 * URLs don't promise an image Content-Type, and Vertex rejects any part
 * labelled application/octet-stream.
 */

import { blobToInline, type InlineImage } from "../../refMedia";
import { findRunAsset } from "../docWriter";
import type { RefAsset } from "../types";

export type InlineImagePart = InlineImage;

/** One image URL's bytes as a base64 part, null on any failure. */
export async function imagePart(url: string): Promise<InlineImagePart | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return await blobToInline(await res.blob());
  } catch {
    return null;
  }
}

/** Resolve image references to inline parts, capped, order preserved. */
export async function refImageParts(
  projectId: string,
  refs: RefAsset[],
  max = 4
): Promise<InlineImagePart[]> {
  const out: InlineImagePart[] = [];
  for (const r of refs) {
    if (out.length >= max) break;
    if (r.kind !== "image") continue;
    const asset = await findRunAsset(projectId, r.mediaId);
    if (!asset) continue;
    const part = await imagePart(asset.url);
    if (part) out.push(part);
  }
  return out;
}

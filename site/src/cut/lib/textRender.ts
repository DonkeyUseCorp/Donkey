"use client";

import { fontStack, type TextOverlay } from "./types";

export const LINE_HEIGHT = 1.25;
export const PLATE_PAD_X = 0.55; // em
export const PLATE_PAD_Y = 0.3; // em
export const PLATE_RADIUS = 0.32; // em
export const PLATE_FILL = "rgba(0, 0, 0, 0.55)";
export const SHADOW = { color: "rgba(0, 0, 0, 0.65)", blur: 14, offsetY: 2 };

/**
 * Render an overlay to a transparent full-frame PNG at the export resolution.
 * Uses the same font stacks and metrics as the DOM preview so the export
 * matches what the user sees.
 */
export async function renderOverlayPng(
  overlay: TextOverlay,
  width: number,
  height: number
): Promise<Blob> {
  // Overlay sizes are frame pixels with a 1080 design short side (9:16 is
  // 1080 wide, 16:9 is 1080 tall), so scaling by the short side keeps text
  // the same visual size in either aspect and at any export resolution.
  const scale = Math.min(width, height) / 1080;
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d")!;

  const fpx = overlay.size * scale;
  ctx.font = `${overlay.weight} ${fpx}px ${fontStack(overlay.font)}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";

  const lines = overlay.text.split("\n");
  const lineH = fpx * LINE_HEIGHT;
  const totalH = lines.length * lineH;
  const cx = overlay.x * width;
  const cy = overlay.y * height;

  if (overlay.plate) {
    const maxW = Math.max(...lines.map((l) => ctx.measureText(l).width), 1);
    const padX = PLATE_PAD_X * fpx;
    const padY = PLATE_PAD_Y * fpx;
    const r = (overlay.plateRadius ?? PLATE_RADIUS) * fpx;
    const w = maxW + padX * 2;
    const h = totalH + padY * 2;
    ctx.fillStyle = PLATE_FILL;
    ctx.beginPath();
    ctx.roundRect(cx - w / 2, cy - h / 2, w, h, r);
    ctx.fill();
  }

  if (overlay.shadow) {
    ctx.shadowColor = SHADOW.color;
    ctx.shadowBlur = SHADOW.blur * scale;
    ctx.shadowOffsetY = SHADOW.offsetY * scale;
  }

  ctx.fillStyle = overlay.color;
  lines.forEach((line, i) => {
    const y = cy - totalH / 2 + lineH * (i + 0.5);
    ctx.fillText(line, cx, y);
  });

  return new Promise((resolve, reject) =>
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("Could not render text overlay."))),
      "image/png"
    )
  );
}

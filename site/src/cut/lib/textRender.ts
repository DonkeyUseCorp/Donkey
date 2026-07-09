"use client";

import { fontStack, type TextOverlay } from "./types";

export const LINE_HEIGHT = 1.25;
export const PLATE_PAD_X = 0.55; // em
export const PLATE_PAD_Y = 0.3; // em
export const PLATE_RADIUS = 0.32; // em
export const PLATE_COLOR = "#000000";
export const PLATE_OPACITY = 0.55;
export const PLATE_FILL = "rgba(0, 0, 0, 0.55)";
export const SHADOW = { color: "rgba(0, 0, 0, 0.65)", blur: 14, offsetY: 2 };

/** A title's plate fill as an rgba() string, defaulting to translucent black
 * when color/opacity are unset. Shared by the preview and the export burn-in. */
export function plateFill(o: { plateColor?: string; plateOpacity?: number }): string {
  const a = o.plateOpacity ?? PLATE_OPACITY;
  const m = /^#?([0-9a-fA-F]{6})$/.exec((o.plateColor ?? PLATE_COLOR).trim());
  if (!m) return `rgba(0, 0, 0, ${a})`;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

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
    ctx.fillStyle = plateFill(overlay);
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
  // Karaoke: draw word by word so the spoken word gets the accent color and an
  // underline; the word index counts across all lines.
  let k = 0;
  lines.forEach((line, i) => {
    const y = cy - totalH / 2 + lineH * (i + 0.5);
    if (overlay.highlightWord === undefined) {
      ctx.fillText(line, cx, y);
      return;
    }
    const words = line.split(" ").filter(Boolean);
    const spaceW = ctx.measureText(" ").width;
    const widths = words.map((w) => ctx.measureText(w).width);
    const lineW = widths.reduce((a, b) => a + b, 0) + spaceW * (words.length - 1);
    let x = cx - lineW / 2;
    ctx.textAlign = "left";
    words.forEach((w, wi) => {
      const active = k === overlay.highlightWord;
      if (active && overlay.highlightMode === "box") {
        // Accent box behind the word, contrast text on top — drawn with the
        // shadow off so the box and its word stay crisp.
        const pad = 0.12 * fpx;
        const prevShadow = ctx.shadowColor;
        ctx.shadowColor = "transparent";
        ctx.fillStyle = overlay.highlightColor ?? "#FFE94A";
        ctx.beginPath();
        ctx.roundRect(x - pad, y - fpx * 0.5 - pad, widths[wi] + pad * 2, fpx + pad * 2, 0.18 * fpx);
        ctx.fill();
        ctx.fillStyle = overlay.highlightText ?? "#111114";
        ctx.fillText(w, x, y);
        ctx.shadowColor = prevShadow;
      } else if (active) {
        ctx.fillStyle = overlay.highlightColor ?? "#FFE94A";
        ctx.fillText(w, x, y);
        if (overlay.highlightMode !== "color")
          ctx.fillRect(x, y + fpx * 0.42, widths[wi], Math.max(2 * scale, fpx * 0.07));
      } else {
        ctx.fillStyle = overlay.color;
        ctx.fillText(w, x, y);
      }
      x += widths[wi] + spaceW;
      k++;
    });
    ctx.textAlign = "center";
  });

  return new Promise((resolve, reject) =>
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("Could not render text overlay."))),
      "image/png"
    )
  );
}

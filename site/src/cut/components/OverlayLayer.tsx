"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { startDrag } from "@/cut/lib/drag";
import { useEditor } from "@/cut/lib/store";
import { cueAt, SUB_STYLE, wrapCaption } from "@/cut/lib/subtitles";
import {
  LINE_HEIGHT,
  PLATE_FILL,
  PLATE_PAD_X,
  PLATE_PAD_Y,
  PLATE_RADIUS,
  plateFill,
  SHADOW,
} from "@/cut/lib/textRender";
import { FRAME, fontStack, type TextOverlay } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

// Plate geometry as CSS, kept in lockstep with the export burn-in metrics.
const PLATE_PADDING = `${PLATE_PAD_Y}em ${PLATE_PAD_X}em`;
const PLATE_RADIUS_EM = `${PLATE_RADIUS}em`;

export function OverlayLayer({ stageWidth }: { stageWidth: number }) {
  const overlays = useEditor((s) => s.overlays);
  const currentTime = useEditor((s) => s.currentTime);
  const skimTime = useEditor((s) => s.skimTime);
  const playing = useEditor((s) => s.playing);
  const selection = useEditor((s) => s.selection);
  // Titles preview under the skimmer too (paused only), matching the canvas.
  const t = !playing && skimTime !== null ? skimTime : currentTime;

  return (
    <div className="pointer-events-none absolute inset-0">
      {overlays.map((o) => {
        const selected = selection?.kind === "text" && selection.id === o.id;
        const inRange = t >= o.start && t <= o.end;
        if (!inRange && !selected) return null;
        return (
          <OverlayItem
            key={o.id}
            overlay={o}
            selected={selected}
            ghost={!inRange}
            stageWidth={stageWidth}
          />
        );
      })}
    </div>
  );
}

/** The active subtitle cue, rendered exactly like the export burn-in.
 * Nothing renders when subtitles are hidden or there is no cue (no speech). */
export function SubtitleLayer({ stageWidth }: { stageWidth: number }) {
  const subtitles = useEditor((s) => s.subtitles);
  const currentTime = useEditor((s) => s.currentTime);
  const skimTime = useEditor((s) => s.skimTime);
  const playing = useEditor((s) => s.playing);
  const aspect = useEditor((s) => s.aspect);
  const t = !playing && skimTime !== null ? skimTime : currentTime;

  if (!subtitles.showOnVideo) return null;
  const cue = cueAt(subtitles.cues, t);
  if (!cue || !cue.text.trim()) return null;

  const scale = stageWidth / FRAME[aspect].w;
  return (
    <div className="pointer-events-none absolute inset-0">
      <div
        className="sub-caption absolute -translate-x-1/2 -translate-y-1/2 text-center whitespace-pre"
        style={{
          left: `${SUB_STYLE.x * 100}%`,
          top: `${SUB_STYLE.y * 100}%`,
          fontSize: SUB_STYLE.size * scale,
          fontFamily: fontStack(SUB_STYLE.font),
          fontWeight: SUB_STYLE.weight,
          lineHeight: LINE_HEIGHT,
          color: SUB_STYLE.color,
          textShadow: `0 ${SHADOW.offsetY * scale}px ${SHADOW.blur * scale}px ${SHADOW.color}`,
          background: PLATE_FILL,
          padding: PLATE_PADDING,
          borderRadius: PLATE_RADIUS_EM,
        }}
      >
        {wrapCaption(cue.text)}
      </div>
    </div>
  );
}

function OverlayItem({
  overlay: o,
  selected,
  ghost,
  stageWidth,
}: {
  overlay: TextOverlay;
  selected: boolean;
  ghost: boolean;
  stageWidth: number;
}) {
  const [editing, setEditing] = useState(false);
  const editRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const frame = useEditor((s) => FRAME[s.aspect]);
  const scale = stageWidth / frame.w;
  const stageHeight = (stageWidth * frame.h) / frame.w;

  useEffect(() => {
    if (editing && editRef.current) {
      editRef.current.focus();
      const range = document.createRange();
      range.selectNodeContents(editRef.current);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
    }
  }, [editing]);

  const style: CSSProperties = {
    left: `${o.x * 100}%`,
    top: `${o.y * 100}%`,
    fontSize: o.size * scale,
    fontFamily: fontStack(o.font),
    fontWeight: o.weight,
    lineHeight: LINE_HEIGHT,
    color: o.color,
    textShadow: o.shadow
      ? `0 ${SHADOW.offsetY * scale}px ${SHADOW.blur * scale}px ${SHADOW.color}`
      : undefined,
    background: o.plate ? plateFill(o) : undefined,
    padding: o.plate ? PLATE_PADDING : undefined,
    borderRadius: o.plate ? `${o.plateRadius ?? PLATE_RADIUS}em` : undefined,
    opacity: ghost ? 0.35 : 1,
  };

  const commitText = () => {
    const text = (editRef.current?.innerText ?? "").replace(/\n+$/, "");
    setEditing(false);
    if (text !== o.text) {
      const s = useEditor.getState();
      s.pushHistory();
      s.updateOverlayTransient(o.id, { text: text || "Your text" });
    }
  };

  return (
    <div
      ref={boxRef}
      className={cn(
        "overlay-item pointer-events-auto absolute -translate-x-1/2 -translate-y-1/2 cursor-grab rounded-xs text-center whitespace-pre active:cursor-grabbing",
        selected && "outline-[1.5px] outline-offset-[3px] outline-[#0a84ff]",
        editing && "cursor-text"
      )}
      style={style}
      onPointerDown={(e) => {
        if (editing) return;
        const s = useEditor.getState();
        s.select({ kind: "text", id: o.id });
        s.pushHistory();
        const { x, y } = o;
        startDrag(e, {
          onMove: (dx, dy) => {
            s.updateOverlayTransient(o.id, {
              x: Math.min(0.98, Math.max(0.02, x + dx / stageWidth)),
              y: Math.min(0.98, Math.max(0.02, y + dy / stageHeight)),
            });
          },
        });
      }}
      onDoubleClick={() => setEditing(true)}
    >
      {editing ? (
        <div
          ref={editRef}
          className="min-w-2 outline-none select-text"
          contentEditable
          suppressContentEditableWarning
          onBlur={commitText}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              commitText();
            }
            e.stopPropagation();
          }}
        >
          {o.text}
        </div>
      ) : (
        <span>{o.text}</span>
      )}
      {selected && !editing && (
        <span
          title="Drag to resize"
          className="overlay-resize absolute -right-2 -bottom-2 size-[13px] cursor-nwse-resize rounded-full border-[2.5px] border-[#0a84ff] bg-white shadow-[0_1px_4px_rgba(0,0,0,0.4)]"
          onPointerDown={(e) => {
            const s = useEditor.getState();
            s.pushHistory();
            const box = boxRef.current!.getBoundingClientRect();
            const cx = box.left + box.width / 2;
            const cy = box.top + box.height / 2;
            const d0 = Math.max(8, Math.hypot(e.clientX - cx, e.clientY - cy));
            const size0 = o.size;
            startDrag(e, {
              onMove: (_dx, _dy, ev) => {
                const d = Math.hypot(ev.clientX - cx, ev.clientY - cy);
                const size = Math.round(Math.min(320, Math.max(16, (size0 * d) / d0)));
                s.updateOverlayTransient(o.id, { size });
              },
            });
          }}
        />
      )}
    </div>
  );
}

"use client";

import { useEffect, useRef, useState } from "react";
import { Folder, FolderPlus, MoreHorizontal, Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

// A desktop-style folder surface shared by the projects home and the library:
// macOS folder tiles, marquee multi-select, drag a selection onto a folder with
// a ghost, and open-to-navigate. Both pages carry a selection as a JSON array of
// ids under their own MIME type, so one drag can move a whole collection.

export interface DeskFolder {
  id: string;
  name: string;
}

export function formatBytes(n: number): string {
  if (n <= 0) return "0 MB";
  const mb = n / (1024 * 1024);
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}

export function readDragIds(e: React.DragEvent, mime: string): string[] {
  const raw = e.dataTransfer.getData(mime);
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? (v as string[]) : [];
  } catch {
    return raw ? [raw] : [];
  }
}

/** A drag ghost mirroring the collection under the cursor: one card, or a small
 * stack labelled with the count. Lives off-screen just long enough for the
 * browser to snapshot it as the drag image. */
export function buildDragGhost(count: number, label: string): HTMLElement {
  const el = document.createElement("div");
  el.style.cssText = "position:absolute;top:-1000px;left:-1000px;pointer-events:none;";
  if (count > 1) {
    const back = document.createElement("div");
    back.style.cssText =
      "position:absolute;inset:0;transform:translate(7px,7px);border-radius:11px;background:rgba(30,30,38,0.55);";
    el.appendChild(back);
  }
  const card = document.createElement("div");
  card.textContent = label;
  card.style.cssText =
    "position:relative;padding:7px 13px;border-radius:11px;background:rgba(18,18,24,0.94);color:#fff;" +
    "font:600 12px/1.2 ui-sans-serif,system-ui,sans-serif;white-space:nowrap;max-width:220px;overflow:hidden;" +
    "text-overflow:ellipsis;box-shadow:0 8px 24px rgba(0,0,0,0.4);";
  el.appendChild(card);
  return el;
}

/** Folder tile glyph: the Lucide folder, filled blue. */
export function FolderGlyph({ className }: { className?: string }) {
  return <Folder className={cn("fill-[#8cc5ff] text-[#8cc5ff]", className)} aria-hidden="true" />;
}

// Elements a press should not turn into a rubber-band: the cards themselves
// (they drag), folder tiles / breadcrumbs, and any interactive control.
const MARQUEE_SKIP =
  "[data-sel-id],[data-no-marquee],button,a,input,textarea,select,[role='button'],[role='menuitem'],[contenteditable='true']";

/** Rubber-band selection like a desktop: press-drag on empty space to sweep a
 * rectangle, and every tile (marked `data-sel-id`) it touches is selected. Armed
 * off the whole `<main>` arena — so it starts anywhere in the content area, not
 * just over the grid — while the left sidebar is left alone. ⇧/⌘ keeps the prior
 * selection; a plain click on empty space clears it. */
export function Marquee({
  className,
  selected,
  setSelected,
  children,
}: {
  className?: string;
  selected: Set<string>;
  setSelected: (s: Set<string>) => void;
  children: React.ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const [rect, setRect] = useState<{ left: number; top: number; width: number; height: number } | null>(
    null
  );

  useEffect(() => {
    const arena = ref.current?.closest("main") ?? ref.current?.parentElement;
    if (!arena) return;
    const onPointerDown = (e: PointerEvent) => {
      if (e.button !== 0 || (e.target as HTMLElement).closest(MARQUEE_SKIP)) return;
      const startX = e.clientX;
      const startY = e.clientY;
      const additive = e.shiftKey || e.metaKey;
      const base = new Set(additive ? selectedRef.current : []);
      let moved = false;

      const onMove = (ev: PointerEvent) => {
        if (!moved && Math.hypot(ev.clientX - startX, ev.clientY - startY) < 4) return;
        moved = true;
        const r = {
          left: Math.min(startX, ev.clientX),
          top: Math.min(startY, ev.clientY),
          width: Math.abs(ev.clientX - startX),
          height: Math.abs(ev.clientY - startY),
        };
        setRect(r);
        const hit = new Set(base);
        ref.current?.querySelectorAll<HTMLElement>("[data-sel-id]").forEach((el) => {
          const b = el.getBoundingClientRect();
          const overlaps =
            b.left < r.left + r.width && b.right > r.left && b.top < r.top + r.height && b.bottom > r.top;
          if (overlaps) hit.add(el.dataset.selId!);
        });
        setSelected(hit);
      };
      const onUp = () => {
        window.removeEventListener("pointermove", onMove);
        if (!moved && !additive) setSelected(new Set());
        setRect(null);
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp, { once: true });
    };
    arena.addEventListener("pointerdown", onPointerDown);
    return () => arena.removeEventListener("pointerdown", onPointerDown);
  }, [setSelected]);

  return (
    <div ref={ref} className="relative min-h-[68vh] flex-1">
      <div className={className}>{children}</div>
      {rect && (
        <div
          className="pointer-events-none fixed z-50 rounded-[3px] border-2 border-[#0a84ff]"
          style={{ left: rect.left, top: rect.top, width: rect.width, height: rect.height }}
        />
      )}
    </div>
  );
}

/** Root breadcrumb shown while a folder is open. The root label is itself a drop
 * target, so a selection can be dragged back out to the top level. */
export function FolderCrumb({
  root,
  name,
  mime,
  onBack,
  onDropOut,
}: {
  root: string;
  name: string;
  mime: string;
  onBack: () => void;
  onDropOut: (ids: string[]) => void;
}) {
  const [over, setOver] = useState(false);
  return (
    <div className="flex items-center gap-2 text-lg font-semibold tracking-tight" data-no-marquee>
      <button
        className={cn(
          "rounded-md px-1.5 py-0.5 text-muted-foreground transition-colors hover:text-foreground",
          over && "bg-primary/15 text-primary"
        )}
        onClick={onBack}
        onDragOver={(e) => {
          if (!Array.from(e.dataTransfer.types).includes(mime)) return;
          e.preventDefault();
          e.dataTransfer.dropEffect = "move";
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={(e) => {
          e.preventDefault();
          setOver(false);
          onDropOut(readDragIds(e, mime));
        }}
      >
        {root}
      </button>
      <span className="text-muted-foreground/50">/</span>
      <span className="truncate">{name}</span>
    </div>
  );
}

/** The desktop-style folder shelf at the root: each folder as a blue folder
 * icon, a drop target for dragged items, plus a dashed "New folder" tile. */
export function FolderShelf<F extends DeskFolder>({
  folders,
  statOf,
  mime,
  onOpen,
  onCreate,
  onRename,
  onDelete,
  onDropIds,
}: {
  folders: F[];
  statOf: (id: string) => { count: number; size?: number };
  mime: string;
  onOpen: (id: string) => void;
  onCreate: (name: string) => void | Promise<void>;
  onRename: (id: string, name: string) => void | Promise<void>;
  onDelete: (id: string) => void | Promise<void>;
  onDropIds: (ids: string[], folderId: string) => void;
}) {
  const [creating, setCreating] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [over, setOver] = useState<string | null>(null);

  return (
    <div className="mb-7 flex flex-wrap gap-2" data-no-marquee>
      {folders.map((f) => {
        const s = statOf(f.id);
        const isOver = over === f.id;
        return editingId === f.id ? (
          <div key={f.id} className="flex w-[92px] flex-col items-center gap-1 pt-1.5">
            <FolderGlyph className="size-[40px]" />
            <Input
              autoFocus
              value={draft}
              className="h-6 w-full text-center text-[11px]"
              onChange={(e) => setDraft(e.target.value)}
              onBlur={() => setEditingId(null)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && draft.trim()) {
                  void onRename(f.id, draft.trim());
                  setEditingId(null);
                } else if (e.key === "Escape") setEditingId(null);
              }}
            />
          </div>
        ) : (
          <div
            key={f.id}
            className="group/f relative flex w-[92px] cursor-pointer flex-col items-center rounded-xl px-2 py-1.5 text-center transition-colors hover:bg-muted/60"
            onClick={() => onOpen(f.id)}
            onDoubleClick={() => {
              setDraft(f.name);
              setEditingId(f.id);
            }}
            onDragOver={(e) => {
              if (!Array.from(e.dataTransfer.types).includes(mime)) return;
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
              setOver(f.id);
            }}
            onDragLeave={() => setOver((o) => (o === f.id ? null : o))}
            onDrop={(e) => {
              e.preventDefault();
              setOver(null);
              onDropIds(readDragIds(e, mime), f.id);
            }}
          >
            <div className={cn("grid place-items-center transition-transform", isOver && "scale-105")}>
              <FolderGlyph className={cn("size-[40px] drop-shadow-sm", isOver && "brightness-110")} />
            </div>
            <span className="mt-0.5 line-clamp-2 max-w-full text-xs font-medium leading-tight">
              {f.name}
            </span>
            <span className="text-[10px] text-muted-foreground tabular-nums">
              {s.count}
              {s.size != null ? ` · ${formatBytes(s.size)}` : ""}
            </span>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label="Folder options"
                    className="absolute top-1 right-1 size-6 bg-black/25 text-white opacity-0 group-hover/f:opacity-100 hover:bg-black/40 hover:text-white data-[state=open]:opacity-100"
                    onClick={(e) => e.stopPropagation()}
                  />
                }
              >
                <MoreHorizontal className="size-3.5" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" onClick={(e) => e.stopPropagation()}>
                <DropdownMenuItem
                  onClick={() => {
                    setDraft(f.name);
                    setEditingId(f.id);
                  }}
                >
                  <Pencil /> Rename
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem variant="destructive" onClick={() => void onDelete(f.id)}>
                  <Trash2 /> Delete folder
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        );
      })}

      {creating ? (
        <div className="flex w-[92px] flex-col items-center gap-1 pt-1.5">
          <FolderGlyph className="size-[40px] opacity-60" />
          <Input
            autoFocus
            value={draft}
            placeholder="Name"
            className="h-6 w-full text-center text-[11px]"
            onChange={(e) => setDraft(e.target.value)}
            onBlur={() => setCreating(false)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && draft.trim()) {
                void onCreate(draft.trim());
                setDraft("");
                setCreating(false);
              } else if (e.key === "Escape") setCreating(false);
            }}
          />
        </div>
      ) : (
        <button
          className="flex w-[92px] flex-col items-center rounded-xl px-2 py-1.5 text-center text-muted-foreground transition-colors hover:bg-muted/60 hover:text-foreground"
          onClick={() => {
            setDraft("");
            setCreating(true);
          }}
        >
          <span className="grid h-[38px] w-[56px] place-items-center rounded-lg border-2 border-dashed border-border">
            <FolderPlus className="size-5" />
          </span>
          <span className="mt-0.5 text-xs">New folder</span>
        </button>
      )}
    </div>
  );
}

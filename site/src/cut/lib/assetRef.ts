"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type React from "react";
import { fetchLibrary, libraryMediaUrl, type LibraryAsset } from "./library";
import type { StockImage } from "./stock";
import { STOCK_IMAGES } from "./stockManifest";
import { useEditor } from "./store";
import type { MediaAsset } from "./types";

// One reference model for every piece of media in the app. A ref names an
// asset wherever it lives — the open project, the shared library, or the
// bundled stock catalog — with enough to preview it (url, kind, duration) and
// to hand it to whatever wants it: an AI chat attachment, an image/video
// generation reference, or a timeline drop.
//
// Refs travel two ways:
// - Native HTML5 drags (cards, tiles, chat) carry a REF_MIME JSON payload;
//   `setRefDragData` on the source, `useAssetDrop` on the target.
// - Pointer drags (timeline clips, which move via pointer capture, not DnD)
//   deliver through the same drop-zone registry with `startPointerRefDrag`.
//
// Refs are also written as mentions in prompt text — `@v2` by short handle or
// `@"asset name"` by name. `refToken` makes the token, `parseMentions`
// resolves tokens back to refs on send.

export type AssetRefScope = "project" | "library" | "stock";
export type AssetRefKind = "video" | "audio" | "image";

export interface AssetRef {
  scope: AssetRefScope;
  id: string;
  /** Display name; mentions resolve against it (`@"beach sunset"`). */
  name: string;
  kind: AssetRefKind;
  /** Fetchable URL for the media itself (previews and frame capture). */
  url: string;
  duration?: number;
  /** Short mention handle (`v2`, `i1`, `a3`), assigned to project assets in
   * media order by `useRefCandidates`. Derived per session, not persisted —
   * display surfaces re-resolve it live so a stale copy never shows. */
  handle?: string;
}

export const refFromAsset = (a: MediaAsset): AssetRef => ({
  scope: "project",
  id: a.id,
  name: a.name,
  kind: a.type,
  url: a.url,
  duration: a.duration,
});

export const refFromLibrary = (a: LibraryAsset): AssetRef => ({
  scope: "library",
  id: a.id,
  name: a.name,
  kind: a.type,
  url: libraryMediaUrl(a.fileName),
  duration: a.duration,
});

export const refFromStock = (i: StockImage): AssetRef => ({
  scope: "stock",
  id: i.id,
  name: i.id,
  kind: "image",
  url: i.file,
});

export const sameRef = (a: AssetRef, b: AssetRef) => a.scope === b.scope && a.id === b.id;

export const addRefOnce = (list: AssetRef[], ref: AssetRef): AssetRef[] =>
  list.some((r) => sameRef(r, ref)) ? list : [...list, ref];

/** Tolerant reader for refs persisted before the scope/kind shape (old chat
 * threads stored `{ id, name, type, duration, url }`). */
export function normalizeRef(v: unknown): AssetRef | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Partial<AssetRef> & { type?: AssetRefKind };
  if (!o.id || !o.name || !o.url) return null;
  return {
    scope: o.scope ?? "project",
    id: o.id,
    name: o.name,
    kind: o.kind ?? o.type ?? "video",
    url: o.url,
    duration: o.duration,
  };
}

// ---------------------------------------------------------------------------
// Drag transport

/** Unified drag payload; every internal media drag carries this alongside any
 * surface-specific MIME (timeline placement, folder moves). */
export const REF_MIME = "application/x-cut-ref";

let inFlightRef: AssetRef | null = null;

export function setRefDragData(e: React.DragEvent, ref: AssetRef) {
  e.dataTransfer.setData(REF_MIME, JSON.stringify(ref));
  if (!e.dataTransfer.effectAllowed || e.dataTransfer.effectAllowed === "uninitialized") {
    e.dataTransfer.effectAllowed = "copy";
  }
  inFlightRef = ref;
}

/** The ref currently being dragged, readable during `dragover`. */
export function draggingRef(): AssetRef | null {
  return inFlightRef;
}

export function hasRefDrag(e: React.DragEvent | DragEvent): boolean {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  return !!dt && Array.from(dt.types).includes(REF_MIME);
}

export function draggedRef(e: React.DragEvent | DragEvent): AssetRef | null {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  if (!dt || !Array.from(dt.types).includes(REF_MIME)) return null;
  try {
    return normalizeRef(JSON.parse(dt.getData(REF_MIME)));
  } catch {
    return null;
  }
}

export function clearRefDrag() {
  inFlightRef = null;
}

// ---------------------------------------------------------------------------
// Drop zones — shared by HTML5 drags and pointer drags

interface RefZone {
  el: HTMLElement;
  onDrop: (ref: AssetRef) => void;
  setActive: (active: boolean) => void;
}

const zones = new Set<RefZone>();

function zoneAt(x: number, y: number): RefZone | null {
  const hit = document.elementFromPoint(x, y);
  if (!hit) return null;
  for (const z of zones) if (z.el.contains(hit)) return z;
  return null;
}

/** Drive a ref through a pointer drag (timeline clips). Call `move` from the
 * drag's onMove so zones under the pointer light up; call `drop` on release —
 * true means a zone took the ref and the source should cancel its own move. */
export function startPointerRefDrag(ref: AssetRef) {
  let x = -1;
  let y = -1;
  return {
    move(ev: PointerEvent) {
      x = ev.clientX;
      y = ev.clientY;
      const z = zoneAt(x, y);
      for (const q of zones) q.setActive(q === z);
    },
    drop(): boolean {
      for (const q of zones) q.setActive(false);
      const z = zoneAt(x, y);
      if (!z) return false;
      z.onDrop(ref);
      return true;
    },
  };
}

/** Make an element accept asset refs from both drag transports:
 * `<div ref={attachTarget} {...targetProps}>` — `active` styles the highlight. */
export function useAssetDrop(onDrop: (ref: AssetRef) => void): {
  active: boolean;
  attachTarget: (el: HTMLElement | null) => void;
  targetProps: Pick<
    React.HTMLAttributes<HTMLElement>,
    "onDragEnter" | "onDragOver" | "onDragLeave" | "onDrop"
  >;
} {
  const [active, setActive] = useState(false);
  const [el, setEl] = useState<HTMLElement | null>(null);
  const depth = useRef(0);
  const cb = useRef(onDrop);
  useEffect(() => {
    cb.current = onDrop;
  });

  // Register the element as a drop zone for pointer-drag delivery.
  useEffect(() => {
    if (!el) return;
    const zone: RefZone = { el, onDrop: (r) => cb.current(r), setActive };
    zones.add(zone);
    return () => {
      zones.delete(zone);
    };
  }, [el]);

  const attachTarget = useCallback((node: HTMLElement | null) => setEl(node), []);

  const targetProps = useMemo<
    Pick<React.HTMLAttributes<HTMLElement>, "onDragEnter" | "onDragOver" | "onDragLeave" | "onDrop">
  >(() => {
    const done = () => {
      depth.current = 0;
      setActive(false);
    };
    return {
      onDragEnter: (e) => {
        if (!hasRefDrag(e)) return;
        e.preventDefault();
        depth.current += 1;
        setActive(true);
      },
      onDragOver: (e) => {
        if (!hasRefDrag(e)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      },
      onDragLeave: (e) => {
        if (!hasRefDrag(e)) return;
        depth.current -= 1;
        if (depth.current <= 0) done();
      },
      onDrop: (e) => {
        done();
        const ref = draggedRef(e);
        if (!ref) return;
        e.preventDefault();
        cb.current(ref);
      },
    };
  }, []);

  return { active, attachTarget, targetProps };
}

// ---------------------------------------------------------------------------
// Candidates and @name mentions

let libraryCache: LibraryAsset[] | null = null;
let libraryLoad: Promise<LibraryAsset[]> | null = null;

/** Everything referenceable right now, in resolution order: the open project's
 * media, then the shared library, then the stock catalog. Names are unique
 * within the list (first scope wins) so a mention resolves to one asset.
 *
 * Project assets get short handles in media order — `v1` videos, `i1`
 * generated stills, `a1` audio — so a prompt can say `@v2` instead of the full
 * name. Library items mention by name; stock ids are already short (`@nature-dunes`). */
export function useRefCandidates(): AssetRef[] {
  const assets = useEditor((s) => s.assets);
  const [lib, setLib] = useState<LibraryAsset[]>(libraryCache ?? []);

  useEffect(() => {
    libraryLoad ??= fetchLibrary()
      .then((d) => (libraryCache = d.assets))
      .catch(() => (libraryCache = []));
    let alive = true;
    void libraryLoad.then((l) => alive && setLib(l));
    return () => {
      alive = false;
    };
  }, []);

  return useMemo(() => {
    const counters = { v: 0, i: 0, a: 0 };
    const project = assets.map((a) => {
      const prefix = a.type === "image" ? "i" : a.type === "video" ? "v" : "a";
      counters[prefix] += 1;
      return { ...refFromAsset(a), handle: `${prefix}${counters[prefix]}` };
    });
    const seen = new Set<string>();
    const out: AssetRef[] = [];
    for (const ref of [
      ...project,
      ...lib.map(refFromLibrary),
      ...STOCK_IMAGES.map(refFromStock),
    ]) {
      const key = ref.name.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(ref);
    }
    return out;
  }, [assets, lib]);
}

/** The prompt token for an asset name: `@name`, quoted when it has spaces. */
export const mentionToken = (name: string) =>
  /[\s"]/.test(name) ? `@"${name.replace(/"/g, "")}"` : `@${name}`;

/** The preferred prompt token for a ref: its short handle (`@v2`) when it has
 * one, the (quoted) name otherwise. */
export const refToken = (ref: AssetRef) =>
  ref.handle ? `@${ref.handle}` : mentionToken(ref.name);

const MENTION_RE = /@(?:"([^"\n]+)"|([^\s"@]+))/g;

/** Resolve one mention body against the candidates: short handle first
 * (`v2`), then exact name (case-insensitive on both). */
export function resolveRefByName(name: string, candidates: AssetRef[]): AssetRef | null {
  const q = name.toLowerCase();
  return (
    candidates.find((c) => c.handle?.toLowerCase() === q) ??
    candidates.find((c) => c.name.toLowerCase() === q) ??
    null
  );
}

/** Split text into literal runs and resolved mention refs, for rendering
 * tokens as interactive chips (hover peek, click to reveal). Unresolved
 * tokens stay literal text. */
export function splitMentions(text: string, candidates: AssetRef[]): (string | AssetRef)[] {
  const parts: (string | AssetRef)[] = [];
  let last = 0;
  for (const m of text.matchAll(MENTION_RE)) {
    const ref = resolveRefByName(m[1] ?? m[2] ?? "", candidates);
    if (!ref) continue;
    if (m.index > last) parts.push(text.slice(last, m.index));
    parts.push(ref);
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}

/** Like {@link splitMentions}, but keeps the literal token text for every
 * resolved mention so an overlay can render it as a pill in place — the
 * rendered characters stay identical to the textarea, so widths align. */
export function highlightMentions(
  text: string,
  candidates: AssetRef[]
): { text: string; ref: AssetRef | null }[] {
  const parts: { text: string; ref: AssetRef | null }[] = [];
  let last = 0;
  for (const m of text.matchAll(MENTION_RE)) {
    const ref = resolveRefByName(m[1] ?? m[2] ?? "", candidates);
    if (!ref) continue;
    if (m.index > last) parts.push({ text: text.slice(last, m.index), ref: null });
    parts.push({ text: m[0], ref });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last), ref: null });
  return parts;
}

/** The current candidate ref for a display name — how card affordances find
 * their short handle. Null when nothing referenceable carries the name. */
export function useRefFor(name: string): AssetRef | null {
  const candidates = useRefCandidates();
  return useMemo(
    () => candidates.find((c) => c.name.toLowerCase() === name.toLowerCase()) ?? null,
    [candidates, name]
  );
}

/** Pull `@name` mentions out of prompt text. Resolved tokens are replaced by
 * the plain asset name (the ref rides along separately); unresolved tokens are
 * left as typed. */
export function parseMentions(
  text: string,
  candidates: AssetRef[]
): { refs: AssetRef[]; text: string } {
  const refs: AssetRef[] = [];
  const out = text.replace(MENTION_RE, (token, quoted: string | undefined, bare: string | undefined) => {
    const ref = resolveRefByName(quoted ?? bare ?? "", candidates);
    if (!ref) return token;
    if (!refs.some((r) => sameRef(r, ref))) refs.push(ref);
    return ref.name;
  });
  return { refs, text: out };
}

/** Resolve a prompt's `@name` mentions and merge them into the already-attached
 * `chips`, de-duplicated. `dropAudio` excludes audio refs — image/video
 * generation take only pictures; chat keeps them. The single place the three
 * send paths (chat, generate image, generate video) share this composition. */
export function collectRefs(
  text: string,
  chips: AssetRef[],
  candidates: AssetRef[],
  opts?: { dropAudio?: boolean }
): { refs: AssetRef[]; text: string } {
  const parsed = parseMentions(text, candidates);
  const mentioned = opts?.dropAudio
    ? parsed.refs.filter((r) => r.kind !== "audio")
    : parsed.refs;
  // Re-resolve each ref's short handle from the live candidates — chips from
  // drags predate handle assignment, and the model reads handles to talk
  // about attachments ("v2").
  const refs = mentioned.reduce(addRefOnce, chips).map((r) => {
    const live = candidates.find((c) => sameRef(c, r));
    return live?.handle ? { ...r, handle: live.handle } : r;
  });
  return { refs, text: parsed.text };
}

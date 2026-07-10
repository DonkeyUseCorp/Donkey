"use client";

import { useMemo, useRef, useState } from "react";
import { AtSign, Check, Copy, Music, X } from "lucide-react";
import {
  mentionToken,
  refToken,
  type AssetRef,
} from "@/cut/lib/assetRef";
import { useRefFor, useRefCandidates } from "@/cut/lib/assetRef";
import { revealRef } from "@/cut/lib/refReveal";
import { formatTime } from "@/cut/lib/time";
import { cn } from "@/lib/utils";

// Shared UI for asset references: the preview thumbnail, attachment chips,
// copy-the-reference affordances, interactive `@v2` token chips (hover peek,
// click to reveal the original asset), and a textarea with `@` autocomplete.
// Every surface that takes references (AI chat, image/video creators)
// composes these.

/** Square media preview for a ref: video poster frame, image, or audio glyph. */
export function RefThumb({ item, className }: { item: AssetRef; className?: string }) {
  return (
    <div
      className={cn(
        "relative shrink-0 overflow-hidden rounded-lg border border-border bg-muted",
        className
      )}
    >
      {item.kind === "video" ? (
        <video
          src={`${item.url}#t=0.1`}
          preload="metadata"
          muted
          playsInline
          className="size-full object-cover"
        />
      ) : item.kind === "image" ? (
        // eslint-disable-next-line @next/next/no-img-element -- refs point at engine/static files, not Next-optimizable images
        <img src={item.url} alt={item.name} loading="lazy" className="size-full object-cover" />
      ) : (
        <div className="grid size-full place-items-center bg-gradient-to-br from-emerald-100 to-emerald-50 text-emerald-600">
          <Music className="size-4.5" />
        </div>
      )}
      {item.duration !== undefined && item.kind !== "image" && (
        <span className="absolute right-1 bottom-1 rounded-[5px] bg-black/65 px-1 py-px font-mono text-[8.5px] text-white tabular-nums">
          {formatTime(item.duration)}
        </span>
      )}
    </div>
  );
}

/** The `v2` badge shown on chips, cards, and the mention menu. */
export function RefHandleBadge({ handle, className }: { handle: string; className?: string }) {
  return (
    <span
      className={cn(
        "rounded-[5px] bg-[#0a84ff]/12 px-1 py-px font-mono text-[9px] font-medium text-[#0a84ff]",
        className
      )}
    >
      {handle}
    </span>
  );
}

/** Hover peek: a larger look at the ref, floated above the anchor. */
function RefPeek({ item, side = "top" }: { item: AssetRef; side?: "top" | "bottom" }) {
  return (
    <div
      className={cn(
        "ref-peek pointer-events-none absolute left-0 z-50 w-44 rounded-xl border border-border bg-popover p-1.5 shadow-xl",
        side === "top" ? "bottom-full mb-1.5" : "top-full mt-1.5"
      )}
    >
      <RefThumb item={item} className="aspect-square w-full" />
      <div className="mt-1 flex items-center gap-1 px-0.5">
        {item.handle && <RefHandleBadge handle={item.handle} />}
        <span className="min-w-0 truncate text-[10.5px] text-foreground">{item.name}</span>
      </div>
      <div className="px-0.5 text-[9.5px] tracking-wide text-muted-foreground uppercase">
        {item.scope} · click to show
      </div>
    </div>
  );
}

/**
 * An inline `@v2` reference token: hover peeks at the asset, click jumps back
 * to it (side panel switches to its tab and the card flashes). Rendered inside
 * chat messages wherever a mention resolved.
 */
export function RefTokenChip({
  item,
  onDark,
  peekSide = "top",
}: {
  item: AssetRef;
  /** Style for a dark bubble (the user message) instead of the light page. */
  onDark?: boolean;
  peekSide?: "top" | "bottom";
}) {
  const [peek, setPeek] = useState(false);
  return (
    <span
      className="relative inline-block"
      onMouseEnter={() => setPeek(true)}
      onMouseLeave={() => setPeek(false)}
    >
      <button
        type="button"
        title={`${item.name} — click to show`}
        className={cn(
          "ref-token rounded-md px-1 font-mono text-[11px] transition-colors",
          onDark
            ? "bg-white/15 text-[#8ec7ff] hover:bg-white/25"
            : "bg-[#0a84ff]/10 text-[#0a84ff] hover:bg-[#0a84ff]/20"
        )}
        onClick={() => revealRef(item)}
      >
        @{item.handle ?? item.name}
      </button>
      {peek && <RefPeek item={item} side={peekSide} />}
    </span>
  );
}

/** Removable attachment chips shown above an input — hover peeks, clicking
 * the thumb reveals the original asset. */
export function RefChips({
  refs,
  onRemove,
  className,
  peekSide = "top",
}: {
  refs: AssetRef[];
  onRemove: (ref: AssetRef) => void;
  className?: string;
  /** Open peeks downward when the chips sit near the top of their panel. */
  peekSide?: "top" | "bottom";
}) {
  const candidates = useRefCandidates();
  if (refs.length === 0) return null;
  return (
    <div className={cn("flex flex-wrap gap-2", className)}>
      {refs.map((r) => {
        // Handles are session-derived; show the live one, not a stored copy.
        const handle =
          candidates.find((c) => c.scope === r.scope && c.id === r.id)?.handle ?? r.handle;
        return (
          <RefChip
            key={`${r.scope}:${r.id}`}
            item={{ ...r, handle }}
            onRemove={onRemove}
            peekSide={peekSide}
          />
        );
      })}
    </div>
  );
}

function RefChip({
  item,
  onRemove,
  peekSide,
}: {
  item: AssetRef;
  onRemove: (ref: AssetRef) => void;
  peekSide: "top" | "bottom";
}) {
  const [peek, setPeek] = useState(false);
  return (
    <div
      className="ref-chip relative"
      onMouseEnter={() => setPeek(true)}
      onMouseLeave={() => setPeek(false)}
    >
      <button
        type="button"
        title={`${item.name} — click to show`}
        className="block text-left"
        onClick={() => revealRef(item)}
      >
        <RefThumb item={item} className="size-14" />
      </button>
      {item.handle && <RefHandleBadge handle={item.handle} className="absolute bottom-1 left-1" />}
      {peek && <RefPeek item={item} side={peekSide} />}
      <button
        aria-label={`Remove ${item.name}`}
        title="Remove"
        className="absolute -top-1.5 -right-1.5 grid size-4.5 place-items-center rounded-full bg-neutral-900 text-white shadow-sm transition-colors hover:bg-neutral-700"
        onClick={() => onRemove(item)}
      >
        <X className="size-3" />
      </button>
    </div>
  );
}

function useCopied(): [boolean, (text: string) => void] {
  const [copied, setCopied] = useState(false);
  const copy = (text: string) => {
    void navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return [copied, copy];
}

/** Hover icon button that copies the asset's reference token (`@v2`, or the
 * `@name` form when it has no short handle). */
export function CopyRefButton({ name, className }: { name: string; className?: string }) {
  const [copied, copy] = useCopied();
  const ref = useRefFor(name);
  const token = ref ? refToken(ref) : mentionToken(name);
  return (
    <span
      role="button"
      aria-label={`Copy reference to ${name}`}
      title={`Copy ${token} to reference in prompts`}
      className={cn(
        "grid size-5 cursor-pointer place-items-center rounded-full bg-black/45 text-white hover:bg-black/65",
        className
      )}
      onClick={(e) => {
        e.stopPropagation();
        e.preventDefault();
        copy(token);
      }}
    >
      {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
    </span>
  );
}

/** A card's name caption with its short handle; clicking copies the reference
 * token, ready to paste into any prompt. */
export function CopyNameLabel({ name, className }: { name: string; className?: string }) {
  const [copied, copy] = useCopied();
  const ref = useRefFor(name);
  const token = ref ? refToken(ref) : mentionToken(name);
  return (
    <button
      type="button"
      title={`Click to copy ${token} — paste it in any prompt to reference this asset`}
      className={cn("flex min-w-0 items-center gap-1 cursor-copy text-left", className)}
      onClick={(e) => {
        e.stopPropagation();
        copy(token);
      }}
    >
      {ref?.handle && <RefHandleBadge handle={ref.handle} className="shrink-0" />}
      {copied ? (
        <span className="truncate text-emerald-600">Copied {token}</span>
      ) : (
        <span className="truncate">{name}</span>
      )}
    </button>
  );
}

/** The open mention being typed at the caret: token start and query text. */
function mentionAtCaret(value: string, caret: number): { start: number; query: string } | null {
  const before = value.slice(0, caret);
  const at = before.lastIndexOf("@");
  if (at < 0) return null;
  if (at > 0 && !/[\s([]/.test(before[at - 1])) return null;
  let query = before.slice(at + 1);
  if (query.startsWith('"')) query = query.slice(1);
  // A finished quote or a newline means the caret left the mention.
  if (query.includes('"') || query.includes("\n") || query.length > 60) return null;
  return { start: at, query };
}

/**
 * Textarea with `@` autocomplete over the given candidates — matches short
 * handles (`@v2`) and names, and inserts the handle token when there is one.
 * Submit behavior is the caller's: `submitKey` picks plain Enter (chat) or
 * ⌘/Ctrl+Enter (creators).
 */
export function MentionTextarea({
  value,
  onChange,
  candidates,
  onSubmit,
  submitKey = "enter",
  menuSide = "top",
  placeholder,
  className,
  rows,
}: {
  value: string;
  onChange: (v: string) => void;
  candidates: AssetRef[];
  onSubmit?: () => void;
  submitKey?: "enter" | "mod-enter";
  /** Where the picker opens relative to the textarea. */
  menuSide?: "top" | "bottom";
  placeholder?: string;
  className?: string;
  rows?: number;
}) {
  const taRef = useRef<HTMLTextAreaElement>(null);
  const [caret, setCaret] = useState(0);
  const [dismissed, setDismissed] = useState<number | null>(null);
  const [sel, setSel] = useState(0);

  const mention = useMemo(() => mentionAtCaret(value, caret), [value, caret]);
  const matches = useMemo(() => {
    if (!mention || dismissed === mention.start) return [];
    const q = mention.query.toLowerCase();
    return candidates
      .filter((c) => c.name.toLowerCase().includes(q) || c.handle?.startsWith(q))
      .slice(0, 8);
  }, [mention, dismissed, candidates]);
  const open = matches.length > 0;
  const selIndex = Math.min(sel, matches.length - 1);

  const syncCaret = () => {
    const el = taRef.current;
    if (el) setCaret(el.selectionStart ?? 0);
  };

  const pick = (ref: AssetRef) => {
    if (!mention) return;
    const token = refToken(ref) + " ";
    const next = value.slice(0, mention.start) + token + value.slice(caret);
    const newCaret = mention.start + token.length;
    onChange(next);
    setSel(0);
    requestAnimationFrame(() => {
      const el = taRef.current;
      if (!el) return;
      el.focus();
      el.setSelectionRange(newCaret, newCaret);
      setCaret(newCaret);
    });
  };

  return (
    <div className="relative min-w-0">
      {open && (
        <div
          className={cn(
            "ref-mention-menu absolute inset-x-0 z-30 flex max-h-56 flex-col overflow-y-auto rounded-lg border border-border bg-popover p-1 shadow-lg",
            menuSide === "top" ? "bottom-full mb-1" : "top-full mt-1"
          )}
        >
          {matches.map((c, i) => (
            <button
              key={`${c.scope}:${c.id}`}
              type="button"
              className={cn(
                "flex w-full items-center gap-2 rounded-md px-1.5 py-1 text-left",
                i === selIndex ? "bg-muted" : "hover:bg-muted/60"
              )}
              onMouseEnter={() => setSel(i)}
              // mousedown, not click: keep focus (and the mention state) in the textarea.
              onMouseDown={(e) => {
                e.preventDefault();
                pick(c);
              }}
            >
              <RefThumb item={c} className="size-8" />
              {c.handle && <RefHandleBadge handle={c.handle} className="shrink-0" />}
              <span className="min-w-0 flex-1 truncate text-[11.5px]">{c.name}</span>
              <span className="shrink-0 text-[9.5px] tracking-wide text-muted-foreground uppercase">
                {c.scope}
              </span>
            </button>
          ))}
          <div className="flex items-center gap-1 px-1.5 pt-1 pb-0.5 text-[10px] text-muted-foreground">
            <AtSign className="size-2.5" /> Reference by handle (@v2) or name
          </div>
        </div>
      )}
      <textarea
        ref={taRef}
        className={className}
        rows={rows}
        placeholder={placeholder}
        value={value}
        onChange={(e) => {
          setDismissed(null);
          onChange(e.target.value);
          setCaret(e.target.selectionStart ?? 0);
        }}
        onSelect={syncCaret}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (open) {
            if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              setSel((selIndex + (e.key === "ArrowDown" ? 1 : matches.length - 1)) % matches.length);
              return;
            }
            if (e.key === "Enter" || e.key === "Tab") {
              e.preventDefault();
              pick(matches[selIndex]);
              return;
            }
            if (e.key === "Escape") {
              e.preventDefault();
              setDismissed(mention?.start ?? null);
              return;
            }
          }
          if (!onSubmit) return;
          const wantsSubmit =
            submitKey === "enter"
              ? e.key === "Enter" && !e.shiftKey
              : e.key === "Enter" && (e.metaKey || e.ctrlKey);
          if (wantsSubmit) {
            e.preventDefault();
            onSubmit();
          }
        }}
      />
    </div>
  );
}

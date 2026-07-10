"use client";

import { useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Maximize2, Search } from "lucide-react";
import { clearRefDrag, refFromStockVideo, setRefDragData } from "@/cut/lib/assetRef";
import { useLightbox } from "@/cut/lib/lightbox";
import { useRevealEffect, useRevealFlash } from "@/cut/lib/refReveal";
import { useVideoGen } from "@/cut/lib/videoGen";
import { STOCK_VIDEO_CATEGORIES, type StockVideo, type StockVideoCategory } from "@/cut/lib/stock";
import { STOCK_VIDEOS } from "@/cut/lib/stockVideoManifest";
import { formatTime } from "@/cut/lib/time";
import { cn } from "@/lib/utils";
import { CopyRefButton, RefHandlePill } from "./AssetRefs";

/** A readable title from a stock id, e.g. "nature-waves" → "Nature Waves". */
const titleFromId = (id: string) =>
  id.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());

// The Video tab's reference browser: a searchable catalog of AI-generated stock
// clips. Every clip carries the prompt that made it — clicking one loads that
// prompt into the generate panel beside it to edit and render on the user's
// account. Videos the user generates show up in that panel, not here.
//
// "Characters" is the featured section: talking-head clips whose prompt ends in
// an editable spoken line, shown as a square-tile row above the footage
// categories (our own take on the pattern).

type View = "all" | StockVideoCategory;

/** The Characters section reads as "Talking Characters" everywhere it titles. */
const viewTitle = (view: Exclude<View, "all">) =>
  view === "Characters" ? "Talking Characters" : view;

// Only categories the catalog actually covers get a chip and a section.
const CATEGORIES = STOCK_VIDEO_CATEGORIES.filter((c) =>
  STOCK_VIDEOS.some((v) => v.category === c)
);

// Character tiles drop the duration badge while every character clip is one
// length; a mixed-length catalog brings it back.
const CHARACTERS_ONE_LENGTH =
  new Set(STOCK_VIDEOS.filter((v) => v.category === "Characters").map((v) => v.duration)).size <= 1;

const chip = (active: boolean) =>
  cn(
    "shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium transition-colors",
    active ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground hover:text-foreground"
  );

export function StockVideosPanel() {
  const [view, setView] = useState<View>("all");
  const [query, setQuery] = useState("");

  // A revealed stock clip may sit behind a category view — open its category
  // so the tile is on screen to flash.
  useRevealEffect((ref) => {
    if (ref.scope !== "stock") return;
    const item = STOCK_VIDEOS.find((v) => v.id === ref.id);
    if (!item) return;
    setView(item.category);
    setQuery("");
  });

  const q = query.trim().toLowerCase();
  const matches = (item: StockVideo) =>
    !q ||
    item.prompt.toLowerCase().includes(q) ||
    item.category.toLowerCase().includes(q) ||
    item.tags.some((t) => t.includes(q));

  const stock = STOCK_VIDEOS.filter(matches);

  return (
    <>
      <div className="flex h-12 shrink-0 items-center pr-2.5 pl-2.5">
        <span className="flex min-w-0 items-center gap-1 text-sm font-semibold tracking-tight">
          {view !== "all" && (
            <button
              title="All stock videos"
              className="grid size-6 shrink-0 place-items-center rounded-md text-muted-foreground hover:text-foreground"
              onClick={() => setView("all")}
            >
              <ChevronLeft className="size-4" />
            </button>
          )}
          <span className={cn("truncate", view === "all" && "pl-1.5")}>
            {view === "all" ? "Stock Videos" : viewTitle(view)}
          </span>
        </span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3.5 pb-4">
        {STOCK_VIDEOS.length === 0 ? (
          <p className="text-[11px] leading-relaxed text-muted-foreground">
            No stock videos are bundled yet.
          </p>
        ) : (
          <>
            <label className="flex shrink-0 items-center gap-2 rounded-lg border border-input px-2.5 py-1.5 focus-within:border-ring">
              <Search className="size-3.5 shrink-0 text-muted-foreground" />
              <input
                className="w-full bg-transparent text-[12px] outline-none placeholder:text-muted-foreground"
                placeholder="Search…"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </label>

            <div className="flex shrink-0 flex-wrap gap-1">
              <button className={chip(view === "all")} onClick={() => setView("all")}>
                All
              </button>
              {CATEGORIES.map((c) => (
                <button key={c} className={chip(view === c)} onClick={() => setView(c)}>
                  {viewTitle(c)}
                </button>
              ))}
            </div>

            {view === "all" ? (
              <>
                {CATEGORIES.map((c) => {
                  const items = stock.filter((v) => v.category === c);
                  if (items.length === 0) return null;
                  const shown = c === "Characters" ? 8 : 6;
                  return (
                    <section key={c} className="shrink-0">
                      <SectionHead
                        title={viewTitle(c)}
                        onViewAll={items.length > shown ? () => setView(c) : undefined}
                      />
                      <CategoryGrid category={c} items={items} limit={shown} />
                    </section>
                  );
                })}
                {stock.length === 0 && <Empty />}
              </>
            ) : (
              (() => {
                const items = stock.filter((v) => v.category === view);
                return items.length > 0 ? (
                  <CategoryGrid category={view} items={items} />
                ) : (
                  <Empty />
                );
              })()
            )}
          </>
        )}
      </div>
    </>
  );
}

/** One category's tile grid — the single place a category's presentation
 * lives: characters render as square face tiles four across, footage as
 * 16:10 tiles two across. */
function CategoryGrid({
  category,
  items,
  limit,
}: {
  category: StockVideoCategory;
  items: StockVideo[];
  limit?: number;
}) {
  const characters = category === "Characters";
  return (
    <div className={cn("grid gap-1.5", characters ? "grid-cols-4" : "grid-cols-2")}>
      {items.slice(0, limit ?? items.length).map((v) => (
        <StockTile
          key={v.id}
          item={v}
          square={characters}
          showDuration={!characters || !CHARACTERS_ONE_LENGTH}
        />
      ))}
    </div>
  );
}

function SectionHead({ title, onViewAll }: { title: string; onViewAll?: () => void }) {
  return (
    <div className="mb-1.5 flex items-center justify-between">
      <span className="text-[12px] font-semibold">{title}</span>
      {onViewAll && (
        <button
          className="flex items-center gap-0.5 text-[11px] text-muted-foreground hover:text-foreground"
          onClick={onViewAll}
        >
          View all
          <ChevronRight className="size-3" />
        </button>
      )}
    </div>
  );
}

/** A stock clip: hover plays it, clicking loads its saved prompt into the
 * generate panel, and it drags as a video ref (chat attachment, generation
 * start frame, timeline drop). Character tiles render square, face-first. */
function StockTile({
  item,
  square = false,
  showDuration = true,
}: {
  item: StockVideo;
  square?: boolean;
  showDuration?: boolean;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { flash, attachReveal } = useRevealFlash("stock", item.id);
  return (
    <div
      ref={attachReveal}
      className={cn(
        "group relative overflow-hidden rounded-lg",
        flash && "ring-2 ring-[#0a84ff] ring-offset-1"
      )}
      onMouseEnter={() => {
        void videoRef.current?.play().catch(() => {});
      }}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = 0;
        }
      }}
    >
      <button
        title={item.prompt}
        className="block w-full outline-none focus-visible:ring-2 focus-visible:ring-ring"
        draggable
        onDragStart={(e) => setRefDragData(e, refFromStockVideo(item))}
        onDragEnd={clearRefDrag}
        onClick={() => useVideoGen.getState().openWith(item.prompt)}
      >
        <video
          ref={videoRef}
          src={item.file}
          poster={item.thumb}
          preload="none"
          muted
          loop
          playsInline
          className={cn("w-full bg-muted object-cover", square ? "aspect-square" : "aspect-[16/10]")}
        />
      </button>
      {showDuration && (
        <span className="pointer-events-none absolute right-1 bottom-1 rounded-[5px] bg-black/65 px-1 py-px font-mono text-[9.5px] text-white tabular-nums">
          {formatTime(item.duration)}
        </span>
      )}
      <RefHandlePill
        token={`@${item.id}`}
        className="absolute bottom-1 left-1 opacity-0 transition-opacity group-hover:opacity-100"
      />
      <div className="absolute top-1 right-1 flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
        <button
          title="Expand"
          className="grid size-5 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
          onClick={() =>
            useLightbox.getState().open({
              src: item.file,
              isVideo: true,
              playable: true,
              name: titleFromId(item.id),
              prompt: item.prompt,
              assetId: null,
            })
          }
        >
          <Maximize2 className="size-3" />
        </button>
        <CopyRefButton name={item.id} />
      </div>
    </div>
  );
}

function Empty() {
  return <p className="text-[11px] text-muted-foreground">No matches.</p>;
}

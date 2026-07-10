"use client";

import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, MoreHorizontal, Search, SlidersHorizontal, Sparkles } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { clearAssetDrag, setAssetDragData } from "@/cut/lib/assetDrag";
import { clearRefDrag, refFromStock, setRefDragData } from "@/cut/lib/assetRef";
import { useRevealEffect, useRevealFlash } from "@/cut/lib/refReveal";
import { useImageGen } from "@/cut/lib/imageGen";
import { STOCK_ASPECT_LABEL, STOCK_CATEGORIES, type StockAspect, type StockCategory, type StockImage } from "@/cut/lib/stock";
import { STOCK_IMAGES } from "@/cut/lib/stockManifest";
import { useEditor } from "@/cut/lib/store";
import type { MediaAsset } from "@/cut/lib/types";
import { cn } from "@/lib/utils";
import { CopyRefButton } from "./AssetRefs";

// The Image tab: a browsable stock catalog of AI-generated images. Every stock
// image carries the prompt that made it — clicking one copies that prompt into
// the generate flyover (over the canvas) to edit and render on the user's
// account. Finished generations land in Media and show up here under Generated.

type View = "all" | StockCategory | "generated";
type AspectFilter = "all" | StockAspect;

/** Categories shown as chips; the rest sit behind the "…" menu. */
const PRIMARY_CHIPS = 4;

const chip = (active: boolean) =>
  cn(
    "shrink-0 rounded-full px-2.5 py-1 text-[11px] font-medium transition-colors",
    active ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground hover:text-foreground"
  );

export function StockImagesPanel() {
  const [view, setView] = useState<View>("all");
  const [query, setQuery] = useState("");
  const [aspect, setAspect] = useState<AspectFilter>("all");
  // Select the stable `assets` reference and derive here — a `.filter()` in the
  // selector returns a fresh array every call, so the panel would re-render on
  // every store write, including usePlayback's per-frame currentTime ticks.
  const assets = useEditor((s) => s.assets);
  const generated = useMemo(() => assets.filter((a) => a.origin === "generated"), [assets]);

  // A revealed stock image may sit behind a category view or the shape
  // filter — open its category so the tile is on screen to flash.
  useRevealEffect((ref) => {
    if (ref.scope !== "stock") return;
    const item = STOCK_IMAGES.find((i) => i.id === ref.id);
    if (!item) return;
    setView(item.category);
    setAspect("all");
    setQuery("");
  });

  const q = query.trim().toLowerCase();
  const matches = (item: StockImage) =>
    (aspect === "all" || item.aspect === aspect) &&
    (!q || item.prompt.toLowerCase().includes(q) || item.category.toLowerCase().includes(q));
  const matchesGenerated = (a: MediaAsset) => !q || a.name.toLowerCase().includes(q);

  const stock = STOCK_IMAGES.filter(matches);
  const shownGenerated = generated.filter(matchesGenerated);
  const overflow = STOCK_CATEGORIES.slice(PRIMARY_CHIPS);

  return (
    <>
      <div className="flex h-12 shrink-0 items-center justify-between pr-2.5 pl-2.5">
        <span className="flex min-w-0 items-center gap-1 text-sm font-semibold tracking-tight">
          {view !== "all" && (
            <button
              title="All stock images"
              className="grid size-6 shrink-0 place-items-center rounded-md text-muted-foreground hover:text-foreground"
              onClick={() => setView("all")}
            >
              <ChevronLeft className="size-4" />
            </button>
          )}
          <span className={cn("truncate", view === "all" && "pl-1.5")}>
            {view === "all" ? "Stock Images" : view === "generated" ? "Generated" : view}
          </span>
        </span>
        <span className="flex shrink-0 items-center">
          <button
            title="Generate an image"
            className="grid size-7 place-items-center rounded-md text-muted-foreground hover:text-foreground"
            onClick={() => useImageGen.getState().openWith("")}
          >
            <Sparkles className="size-4" />
          </button>
          <DropdownMenu>
            <DropdownMenuTrigger
              title="Filter by shape"
              className={cn(
                "grid size-7 place-items-center rounded-md hover:text-foreground",
                aspect === "all" ? "text-muted-foreground" : "text-primary"
              )}
            >
              <SlidersHorizontal className="size-4" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuRadioGroup value={aspect} onValueChange={(v) => setAspect(v as AspectFilter)}>
                <DropdownMenuRadioItem value="all">All</DropdownMenuRadioItem>
                {(Object.keys(STOCK_ASPECT_LABEL) as StockAspect[]).map((a) => (
                  <DropdownMenuRadioItem key={a} value={a}>
                    {STOCK_ASPECT_LABEL[a]}
                  </DropdownMenuRadioItem>
                ))}
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3.5 pb-4">
        <label className="flex shrink-0 items-center gap-2 rounded-lg border border-input px-2.5 py-1.5 focus-within:border-ring">
          <Search className="size-3.5 shrink-0 text-muted-foreground" />
          <input
            className="w-full bg-transparent text-[12px] outline-none placeholder:text-muted-foreground"
            placeholder="Search…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>

        <div className="flex shrink-0 flex-wrap gap-1.5">
          <button className={chip(view === "all")} onClick={() => setView("all")}>
            All
          </button>
          {STOCK_CATEGORIES.slice(0, PRIMARY_CHIPS).map((c) => (
            <button key={c} className={chip(view === c)} onClick={() => setView(c)}>
              {c}
            </button>
          ))}
          {(view === "generated" || overflow.includes(view as StockCategory)) && (
            <button className={chip(true)}>{view === "generated" ? "Generated" : view}</button>
          )}
          <DropdownMenu>
            <DropdownMenuTrigger className={chip(false)} title="More categories">
              <MoreHorizontal className="size-3.5" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start">
              {overflow.map((c) => (
                <DropdownMenuItem key={c} onClick={() => setView(c)}>
                  {c}
                </DropdownMenuItem>
              ))}
              <DropdownMenuItem onClick={() => setView("generated")}>Generated</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>

        {view === "all" ? (
          <>
            {shownGenerated.length > 0 && (
              <GeneratedSection assets={shownGenerated.slice(0, 6)} onViewAll={() => setView("generated")} truncated={shownGenerated.length > 6} />
            )}
            {STOCK_CATEGORIES.map((c) => {
              const items = stock.filter((i) => i.category === c);
              if (items.length === 0) return null;
              return (
                <section key={c} className="shrink-0">
                  <SectionHead title={c} onViewAll={items.length > 6 ? () => setView(c) : undefined} />
                  <div className="grid grid-cols-3 gap-1.5">
                    {items.slice(0, 6).map((i) => (
                      <StockTile key={i.id} item={i} />
                    ))}
                  </div>
                </section>
              );
            })}
            {stock.length === 0 && shownGenerated.length === 0 && <Empty />}
          </>
        ) : view === "generated" ? (
          shownGenerated.length > 0 ? (
            <div className="grid grid-cols-2 gap-1.5">
              {shownGenerated.map((a) => (
                <GeneratedTile key={a.id} asset={a} />
              ))}
            </div>
          ) : (
            <p className="text-[11px] leading-relaxed text-muted-foreground">
              Images you generate land here and in Media.
            </p>
          )
        ) : (
          (() => {
            const items = stock.filter((i) => i.category === view);
            return items.length > 0 ? (
              <div className="grid grid-cols-2 gap-1.5">
                {items.map((i) => (
                  <StockTile key={i.id} item={i} big />
                ))}
              </div>
            ) : (
              <Empty />
            );
          })()
        )}
      </div>
    </>
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

function GeneratedSection({
  assets,
  onViewAll,
  truncated,
}: {
  assets: MediaAsset[];
  onViewAll: () => void;
  truncated: boolean;
}) {
  return (
    <section className="shrink-0">
      <SectionHead title="Generated" onViewAll={truncated ? onViewAll : undefined} />
      <div className="grid grid-cols-3 gap-1.5">
        {assets.map((a) => (
          <GeneratedTile key={a.id} asset={a} />
        ))}
      </div>
    </section>
  );
}

/** A stock thumbnail; clicking copies its saved prompt into the flyover, and
 * it drags as an asset ref (chat attachment, generation reference). */
function StockTile({ item, big }: { item: StockImage; big?: boolean }) {
  const { flash, attachReveal } = useRevealFlash("stock", item.id);
  return (
    <div
      ref={attachReveal}
      className={cn(
        "group relative overflow-hidden rounded-lg",
        flash && "ring-2 ring-[#0a84ff] ring-offset-1"
      )}
    >
      <button
        title={item.prompt}
        className="block w-full outline-none focus-visible:ring-2 focus-visible:ring-ring"
        draggable
        onDragStart={(e) => setRefDragData(e, refFromStock(item))}
        onDragEnd={clearRefDrag}
        onClick={() => useImageGen.getState().openWith(item.prompt)}
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- bundled static thumbs on a client-only page */}
        <img
          src={item.file}
          alt={item.prompt}
          loading="lazy"
          className={cn(
            "w-full bg-muted object-cover transition-transform group-hover:scale-[1.04]",
            big ? "aspect-[16/10]" : "aspect-[4/3]"
          )}
        />
      </button>
      <CopyRefButton
        name={item.id}
        className="absolute top-1 right-1 opacity-0 transition-opacity group-hover:opacity-100"
      />
    </div>
  );
}

/** A previously generated image (an 8s still asset); clicking reopens its
 * prompt in the flyover to iterate on it, and it drags like any media card. */
function GeneratedTile({ asset }: { asset: MediaAsset }) {
  return (
    <div className="group relative overflow-hidden rounded-lg">
      <button
        title={asset.name}
        className="block w-full outline-none focus-visible:ring-2 focus-visible:ring-ring"
        draggable
        onDragStart={(e) => setAssetDragData(e, asset.id)}
        onDragEnd={clearAssetDrag}
        onClick={() => useImageGen.getState().openWith(asset.name)}
      >
        <video
          muted
          playsInline
          preload="metadata"
          src={`${asset.url}#t=0.1`}
          className="aspect-[4/3] w-full bg-black object-cover transition-transform group-hover:scale-[1.04]"
        />
      </button>
      <CopyRefButton
        name={asset.name}
        className="absolute top-1 right-1 opacity-0 transition-opacity group-hover:opacity-100"
      />
    </div>
  );
}

function Empty() {
  return <p className="text-[11px] text-muted-foreground">No matches.</p>;
}

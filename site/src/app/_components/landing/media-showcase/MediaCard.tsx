import { useEffect, useRef } from "react";
import Image from "next/image";
import { Film, ImageIcon, Maximize2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { type MediaShowcaseItem } from "@/app/_components/landing/media-showcase/data";

// Width-over-height ratio of the tile, from the exact ratio the item was
// generated at (the "W:H" settings tag), falling back to its aspect bucket.
export function tileRatio(item: MediaShowcaseItem): number {
  const token = item.settings?.find((s) => /^\d+:\d+$/.test(s));
  if (token) {
    const [w, h] = token.split(":").map(Number);
    if (w && h) return w / h;
  }
  return item.aspect === "portrait" ? 3 / 4 : item.aspect === "square" ? 1 : 16 / 9;
}

// Ratio used for row layout: very tall media (9:16) gets a floor of 0.7 so it
// never collapses into a sliver inside a mixed row — the clip center-crops
// into the wider box via object-cover. Uniform vertical walls (UGC filter)
// keep the true ratio.
export function layoutRatio(item: MediaShowcaseItem): number {
  return Math.max(0.7, tileRatio(item));
}

type Props = {
  item: MediaShowcaseItem;
  onOpen: (item: MediaShowcaseItem) => void;
  // Above-the-fold tile: preload its image eagerly (it is a likely LCP).
  priority?: boolean;
  // Flex sizing from the row packer: grow shares row width by aspect ratio so
  // tiles in a row end up the same height; a sparse last row passes grow 0
  // with a fixed pixel basis instead.
  pack?: { grow: number; basis: string };
  // Uniform-grid mode for all-vertical sets (e.g. the UGC & Ads filter):
  // fixed 4-up columns (2-up on small screens, 5-up on very wide) instead of
  // justified sizing, so 8 clips land as balanced rows like a vertical-video
  // wall.
  uniformGrid?: boolean;
};

// One tile in the justified mosaic. The flex-grow/flex-basis pair is the
// classic justified-gallery trick: both scale with the tile's aspect ratio, so
// every tile in a flex row ends up the same height and each row fills the full
// width — landscape rows come out short, vertical-video rows tall. The row
// height scale lives in the grid container's --row-h variable.
export function MediaCard({
  item,
  onOpen,
  pack,
  priority = false,
  uniformGrid = false,
}: Props) {
  const isVideo = item.kind === "video";
  const KindIcon = isVideo ? Film : ImageIcon;
  const ratio = uniformGrid ? tileRatio(item) : layoutRatio(item);
  const videoRef = useRef<HTMLVideoElement>(null);

  // Every clip plays while it's on screen and pauses off screen.
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) video.play().catch(() => {});
        else video.pause();
      },
      { threshold: 0.35 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, []);

  return (
    <button
      className={cn(
        "group relative block overflow-hidden rounded-2xl border-2 border-ink text-left",
        uniformGrid &&
          "grow basis-[calc(50%-8px)] md:basis-[calc(25%-12px)] 2xl:basis-[calc(20%-13px)]",
      )}
      onClick={() => onOpen(item)}
      style={{
        aspectRatio: String(ratio),
        ...(uniformGrid
          ? {}
          : pack
            ? { flexGrow: pack.grow, flexBasis: pack.basis, minWidth: 0 }
            : {
                flexGrow: ratio * 100,
                flexBasis: `calc(var(--row-h) * ${ratio})`,
              }),
      }}
      type="button"
    >
      <Image
        alt={item.title}
        className="object-cover transition-transform duration-300 group-hover:scale-[1.03]"
        fill
        priority={priority}
        sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw"
        src={item.thumbnailSrc}
      />

      {/* Preview clip over the poster image. preload="none" keeps the grid
          from downloading every clip up front; play() loads on first view. */}
      {isVideo ? (
        <video
          className="absolute inset-0 h-full w-full object-cover"
          loop
          muted
          playsInline
          preload="none"
          ref={videoRef}
          src={item.mediaSrc}
        />
      ) : null}

      <span className="absolute top-3 left-3 inline-flex items-center gap-1.5 rounded-full border-2 border-ink bg-cream px-2.5 py-1 text-[11px] font-semibold tracking-[0.04em] uppercase">
        <KindIcon size={12} />
        {item.kind}
      </span>

      <div className="absolute inset-x-0 bottom-0 flex items-end justify-between gap-2 bg-gradient-to-t from-black/75 via-black/25 to-transparent p-3 pt-8">
        <span className="text-[14px] leading-tight font-semibold text-white">
          {item.title}
        </span>
        <span className="shrink-0 rounded-full bg-white/90 p-1.5 text-ink opacity-0 transition-opacity duration-200 group-hover:opacity-100">
          <Maximize2 size={14} />
        </span>
      </div>
    </button>
  );
}

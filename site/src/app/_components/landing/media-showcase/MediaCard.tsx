import Image from "next/image";
import { Film, ImageIcon, Maximize2 } from "lucide-react";

import { cn } from "@/lib/utils";
import {
  type MediaAspect,
  type MediaShowcaseItem,
} from "@/app/_components/landing/media-showcase/data";

export const aspectClass: Record<MediaAspect, string> = {
  portrait: "aspect-[3/4]",
  landscape: "aspect-[16/9]",
  square: "aspect-square",
};

type Props = {
  item: MediaShowcaseItem;
  onOpen: (item: MediaShowcaseItem) => void;
};

// One masonry tile showing the item's media. Clicking opens the prompt dialog.
export function MediaCard({ item, onOpen }: Props) {
  const isVideo = item.kind === "video";
  const KindIcon = isVideo ? Film : ImageIcon;

  return (
    <button
      className="group relative mb-5 block w-full break-inside-avoid overflow-hidden rounded-2xl border-2 border-ink text-left"
      onClick={() => onOpen(item)}
      type="button"
    >
      <div className={cn("relative w-full", aspectClass[item.aspect])}>
        <Image
          alt={item.title}
          className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-[1.03]"
          fill
          sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw"
          src={item.thumbnailSrc}
        />

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
      </div>
    </button>
  );
}

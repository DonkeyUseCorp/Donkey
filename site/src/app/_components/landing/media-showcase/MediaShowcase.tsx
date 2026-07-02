"use client";

import { useMemo, useState } from "react";
import { ArrowRight } from "lucide-react";

import { Headline, PillButton } from "@/app/_components/landing/LandingPrimitives";
import {
  CategoryChips,
  type CategoryFilter,
} from "@/app/_components/landing/media-showcase/CategoryChips";
import { MediaCard } from "@/app/_components/landing/media-showcase/MediaCard";
import { MediaDetailDialog } from "@/app/_components/landing/media-showcase/MediaDetailDialog";
import {
  getItemsByCategory,
  type MediaShowcaseItem,
} from "@/app/_components/landing/media-showcase/data";

type Props = {
  // Section heading, e.g. "Media Donkey can make".
  heading: string;
  blurb?: string;
  // Cap the number of tiles shown (homepage teaser). Omit to show all.
  limit?: number;
  // When set, renders a "See all" pill (homepage → /use-cases).
  viewAllHref?: string;
};

// Media-generation showcase: filterable grid of example images/videos. Clicking
// a tile reveals its prompt in a dialog with a copy-to-clipboard action.
export function MediaShowcase({ blurb, heading, limit, viewAllHref }: Props) {
  const [category, setCategory] = useState<CategoryFilter>("All");
  const [selected, setSelected] = useState<MediaShowcaseItem | null>(null);

  const items = useMemo(() => {
    const filtered = getItemsByCategory(category);
    return limit ? filtered.slice(0, limit) : filtered;
  }, [category, limit]);

  return (
    <section className="w-full py-16 md:py-24">
      <div className="mx-auto w-full max-w-[1400px] px-6 md:px-12">
        <div className="flex flex-col gap-6 md:flex-row md:items-end md:justify-between">
          <div className="max-w-[720px]">
            <Headline size="lg">{heading}</Headline>
            {blurb ? (
              <p className="mt-5 text-[17px] leading-[1.55] text-[#454545] md:text-[19px]">
                {blurb}
              </p>
            ) : null}
          </div>
          {viewAllHref ? (
            <PillButton href={viewAllHref} variant="secondary">
              See all use cases
              <ArrowRight size={16} />
            </PillButton>
          ) : null}
        </div>

        <div className="mt-8">
          <CategoryChips onSelect={setCategory} selected={category} />
        </div>
      </div>

      {/* The grid alone bleeds to the viewport edge; heading and chips stay in the page container. */}
      <div className="mt-8 columns-1 gap-5 px-6 sm:columns-2 md:px-12 lg:columns-3 xl:columns-4 2xl:columns-5">
        {items.map((item) => (
          <MediaCard item={item} key={item.id} onOpen={setSelected} />
        ))}
      </div>

      <MediaDetailDialog item={selected} onClose={() => setSelected(null)} />
    </section>
  );
}

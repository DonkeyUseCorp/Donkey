"use client";

import { cn } from "@/lib/utils";
import {
  type MediaCategory,
  mediaCategories,
} from "@/app/_components/landing/media-showcase/data";

export type CategoryFilter = MediaCategory | "All";

type Props = {
  onSelect: (category: CategoryFilter) => void;
  selected: CategoryFilter;
};

const filters: CategoryFilter[] = ["All", ...mediaCategories];

// Horizontal row of brand pills that filter the media grid. Active pill fills
// coral; the rest sit on cream. Mirrors the active/idle chip feel of the
// DonkeySkills rail.
export function CategoryChips({ onSelect, selected }: Props) {
  return (
    <div className="flex flex-wrap gap-2.5">
      {filters.map((filter) => {
        const active = filter === selected;
        return (
          <button
            aria-pressed={active}
            className={cn(
              "rounded-full border-2 border-ink px-4 py-2 text-[14px] font-semibold transition-colors",
              active ? "bg-coral text-ink" : "bg-cream text-ink hover:bg-white",
            )}
            key={filter}
            onClick={() => onSelect(filter)}
            type="button"
          >
            {filter}
          </button>
        );
      })}
    </div>
  );
}

"use client";

import { useEffect, useMemo, useRef, useState } from "react";

import { Headline } from "@/app/_components/landing/LandingPrimitives";
import {
  CategoryChips,
  type CategoryFilter,
} from "@/app/_components/landing/media-showcase/CategoryChips";
import {
  layoutRatio,
  MediaCard,
  tileRatio,
} from "@/app/_components/landing/media-showcase/MediaCard";
import { MediaDetailDialog } from "@/app/_components/landing/media-showcase/MediaDetailDialog";
import {
  getItemsByCategory,
  type MediaShowcaseItem,
} from "@/app/_components/landing/media-showcase/data";

type Props = {
  // Section heading, e.g. "Donkey can make".
  heading: string;
  blurb?: string;
};

const GAP = 16;

// Justified row packing: balance the items (in order) into rows whose heights
// land near a clamped target, so tiles never degenerate-stretch far past it.
// Row count comes from how many target-height rows the items naturally fill;
// a small DP then splits the items into that many contiguous rows with the
// most even ratio sums, so no row ends up starved and over-stretched.
function packRows(
  items: MediaShowcaseItem[],
  width: number,
): { rows: MediaShowcaseItem[][]; targetHeight: number } {
  const targetHeight = Math.min(470, Math.max(240, width / 4.8));
  const ratios = items.map(layoutRatio);
  const naturalWidth = ratios.reduce(
    (sum, ratio) => sum + ratio * targetHeight + GAP,
    0,
  );
  const rowCount = Math.min(
    items.length,
    Math.max(1, Math.round(naturalWidth / width)),
  );
  if (rowCount === 1) return { rows: [items], targetHeight };

  const prefix = [0];
  for (const ratio of ratios) prefix.push(prefix[prefix.length - 1] + ratio);
  const rangeRatio = (from: number, to: number) => prefix[to] - prefix[from];
  const targetPerRow = prefix[items.length] / rowCount;

  // cost[k][i] = best squared deviation splitting the first i items into k
  // rows; split[k][i] remembers where row k starts.
  const cost = Array.from({ length: rowCount + 1 }, () =>
    new Array<number>(items.length + 1).fill(Infinity),
  );
  const split = Array.from({ length: rowCount + 1 }, () =>
    new Array<number>(items.length + 1).fill(0),
  );
  cost[0][0] = 0;
  for (let k = 1; k <= rowCount; k += 1) {
    for (let end = k; end <= items.length; end += 1) {
      for (let start = k - 1; start < end; start += 1) {
        if (cost[k - 1][start] === Infinity) continue;
        const candidate =
          cost[k - 1][start] + (rangeRatio(start, end) - targetPerRow) ** 2;
        if (candidate < cost[k][end]) {
          cost[k][end] = candidate;
          split[k][end] = start;
        }
      }
    }
  }

  const bounds: number[] = [];
  let end = items.length;
  for (let k = rowCount; k >= 1; k -= 1) {
    bounds.unshift(end);
    end = split[k][end];
  }
  const rows: MediaShowcaseItem[][] = [];
  let start = 0;
  for (const bound of bounds) {
    rows.push(items.slice(start, bound));
    start = bound;
  }
  return { rows, targetHeight };
}

// Media-generation showcase: filterable grid of example images/videos. Clicking
// a tile reveals its prompt in a dialog with a copy-to-clipboard action.
export function MediaShowcase({ blurb, heading }: Props) {
  const [category, setCategory] = useState<CategoryFilter>("All");
  const [selected, setSelected] = useState<MediaShowcaseItem | null>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const [gridWidth, setGridWidth] = useState<number | null>(null);

  useEffect(() => {
    const grid = gridRef.current;
    if (!grid) return;
    const observer = new ResizeObserver(([entry]) =>
      setGridWidth(entry.contentRect.width),
    );
    observer.observe(grid);
    return () => observer.disconnect();
  }, []);

  const items = useMemo(() => getItemsByCategory(category), [category]);

  // An all-vertical selection (e.g. UGC & Ads) renders as a uniform column
  // grid instead of justified rows, so its clips split into balanced rows.
  const uniformGrid =
    items.length > 0 && items.every((item) => tileRatio(item) < 1);

  const packed =
    !uniformGrid && gridWidth ? packRows(items, gridWidth) : null;
  const totalRatio = items.reduce((sum, item) => sum + layoutRatio(item), 0);

  return (
    <section className="w-full py-16 md:py-24">
      <div className="mx-auto w-full max-w-[1400px] px-6 md:px-12">
        <div className="max-w-[720px]">
          <Headline size="lg">{heading}</Headline>
          {blurb ? (
            <p className="mt-5 text-[17px] leading-[1.55] text-[#454545] md:text-[19px]">
              {blurb}
            </p>
          ) : null}
        </div>

        <div className="mt-8">
          <CategoryChips onSelect={setCategory} selected={category} />
        </div>
      </div>

      {/* The mosaic alone bleeds to the viewport edge; heading and chips stay
          in the page container. */}
      <div className="mt-8 px-6 md:px-12" ref={gridRef}>
        {packed ? (
          <div className="flex flex-col gap-4">
            {packed.rows.map((row, rowIndex) => {
              const rowRatio = row.reduce(
                (sum, item) => sum + layoutRatio(item),
                0,
              );
              // Stretch rows to fill the full width, except a sparse final
              // row, whose tiles keep their natural target size instead of
              // blowing up.
              const stretch =
                rowIndex < packed.rows.length - 1 ||
                rowRatio >= 0.6 * (totalRatio / packed.rows.length);
              return (
                <div className="flex gap-4" key={row[0].id}>
                  {row.map((item) => (
                    <MediaCard
                      item={item}
                      key={item.id}
                      onOpen={setSelected}
                      priority={rowIndex === 0}
                      pack={
                        stretch
                          ? { grow: layoutRatio(item), basis: "0px" }
                          : {
                              grow: 0,
                              basis: `${Math.round(layoutRatio(item) * packed.targetHeight)}px`,
                            }
                      }
                    />
                  ))}
                </div>
              );
            })}
          </div>
        ) : (
          // Uniform column grid for all-vertical sets, and the pre-measure
          // fallback frame for the packed layout's first paint.
          <div className="flex flex-wrap gap-4 [--row-h:180px] after:grow-[9999] after:content-[''] sm:[--row-h:220px] lg:[--row-h:260px] xl:[--row-h:320px] 2xl:[--row-h:400px]">
            {items.map((item, index) => (
              <MediaCard
                item={item}
                key={item.id}
                onOpen={setSelected}
                priority={index < 5}
                uniformGrid={uniformGrid}
              />
            ))}
          </div>
        )}
      </div>

      <MediaDetailDialog item={selected} onClose={() => setSelected(null)} />
    </section>
  );
}

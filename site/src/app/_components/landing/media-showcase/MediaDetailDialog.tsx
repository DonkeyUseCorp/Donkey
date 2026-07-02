"use client";

import Image from "next/image";
import { ArrowRight, Film, ImageIcon } from "lucide-react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { CopyPromptButton } from "@/app/_components/landing/media-showcase/CopyPromptButton";
import { type MediaShowcaseItem } from "@/app/_components/landing/media-showcase/data";

type Props = {
  item: MediaShowcaseItem | null;
  onClose: () => void;
};

// Reveals an item's media large alongside its generation prompt. The visitor
// copies the prompt and pastes it into Donkey — no remix.
export function MediaDetailDialog({ item, onClose }: Props) {
  const KindIcon = item?.kind === "video" ? Film : ImageIcon;

  return (
    <Dialog
      open={item !== null}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      {/* Lightbox: a centered card over a dark backdrop, so clicking outside
          it dismisses. sm:max-w-none: the base DialogContent sets sm:max-w-sm,
          which an unprefixed max-w-none loses to at ≥sm widths; gap-0 clears
          its gap-4 so the panel's border sits flush against the media pane. */}
      <DialogContent
        className="flex h-[92dvh] w-[95vw] max-w-none flex-col gap-0 overflow-hidden rounded-2xl border-2 border-ink bg-cream p-0 text-ink ring-0 sm:max-w-none md:flex-row"
        overlayClassName="bg-black/70"
      >
        {item ? (
          <>
            <div className="flex h-[45vh] w-full shrink-0 items-center justify-center bg-ink md:h-auto md:flex-1">
              {/* Cap the media's rendered size so it stays near source
                  resolution on huge screens instead of stretching wall to
                  wall; it still shrinks to fit smaller panes. */}
              <div className="relative h-full max-h-[1080px] w-full max-w-[1440px]">
                {item.kind === "video" ? (
                  <video
                    autoPlay
                    className="absolute inset-0 h-full w-full object-contain"
                    loop
                    muted
                    playsInline
                    src={item.mediaSrc}
                  />
                ) : (
                  <Image
                    alt={item.title}
                    className="object-contain"
                    fill
                    sizes="(max-width: 768px) 100vw, 70vw"
                    src={item.mediaSrc}
                  />
                )}
              </div>
            </div>

            <div className="flex w-full flex-1 flex-col gap-5 overflow-y-auto p-6 md:w-[420px] md:max-w-[420px] md:flex-none md:border-l-2 md:border-ink md:p-8 lg:w-[480px] lg:max-w-[480px]">
              <div>
                <span className="inline-flex items-center gap-1.5 rounded-full border-2 border-ink bg-white px-3 py-1 text-[11px] font-semibold tracking-[0.06em] uppercase">
                  <KindIcon size={12} />
                  {item.category}
                </span>
                <DialogTitle className="mt-3 text-[26px] leading-[1.05] font-semibold text-ink">
                  {item.title}
                </DialogTitle>
                <DialogDescription className="sr-only">
                  AI-generated {item.kind} example with a copyable prompt.
                </DialogDescription>
              </div>

              <div className="rounded-xl border-2 border-ink bg-white p-4">
                <div className="text-[12px] font-semibold tracking-[0.12em] text-[#666] uppercase">
                  Prompt
                </div>
                <p className="mt-2 font-code text-[14px] leading-[1.55] text-ink">
                  {item.prompt}
                </p>
              </div>

              <div>
                <CopyPromptButton text={item.prompt} />
              </div>

              {item.settings?.length ? (
                <div>
                  <div className="text-[12px] font-semibold tracking-[0.12em] text-[#666] uppercase">
                    Settings
                  </div>
                  <div className="mt-2 flex flex-wrap gap-2">
                    {item.settings.map((setting) => (
                      <span
                        className="rounded-md border-2 border-ink bg-cream px-2.5 py-1 text-[12px] font-semibold"
                        key={setting}
                      >
                        {setting}
                      </span>
                    ))}
                  </div>
                </div>
              ) : null}

              <div className="mt-auto pt-4">
                <p className="text-[14px] leading-[1.5] text-[#333]">
                  Paste this prompt into Donkey to generate your own.
                </p>
                <div className="mt-3">
                  <PillButton href="/install" variant="dark" size="sm">
                    Install Donkey
                    <ArrowRight size={16} />
                  </PillButton>
                </div>
              </div>
            </div>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

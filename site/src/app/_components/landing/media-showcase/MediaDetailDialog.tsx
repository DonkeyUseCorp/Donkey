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
      <DialogContent className="flex h-dvh w-screen max-w-none flex-col overflow-hidden rounded-none border-0 bg-cream p-0 text-ink ring-0 md:flex-row">
        {item ? (
          <>
            <div className="relative h-[45vh] w-full shrink-0 bg-ink md:h-auto md:w-[68%] md:flex-1">
              {item.kind === "video" ? (
                <video
                  autoPlay
                  className="absolute inset-0 h-full w-full object-contain"
                  controls
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

              <div className="mt-auto rounded-xl border-2 border-dashed border-ink/40 bg-white/70 p-4">
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

import Image from "next/image";

import { VisionOverlay } from "@/app/donkeyvision/VisionOverlay";
import { VISION_DATASETS } from "@/app/donkeyvision/visionData";

const spotify =
  VISION_DATASETS.find((d) => d.key === "spotify") ?? VISION_DATASETS[0];

export function VisionPreview() {
  return (
    <div className="relative w-full min-w-0 max-w-full self-center">
      <div className="relative w-full max-w-full overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC]">
        <div className="flex items-center justify-between border-b-2 border-[#0F0E0D] bg-white px-4 py-[9px]">
          <div className="flex items-center gap-2">
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868]" />
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#F5D875]" />
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#B7E4C7]" />
          </div>
          <span className="text-[10px] font-semibold">Spotify</span>
        </div>
        <div
          className="relative w-full"
          style={{ aspectRatio: `${spotify.width} / ${spotify.height}` }}
        >
          <Image
            src={spotify.image}
            alt={`${spotify.title} screenshot with detected controls`}
            fill
            priority
            sizes="(max-width: 1100px) 100vw, 700px"
            className="object-cover"
          />
          <VisionOverlay dataset={spotify} />
        </div>
      </div>
    </div>
  );
}

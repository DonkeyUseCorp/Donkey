"use client";

import type { ReactNode } from "react";
import { Clapperboard, Ellipsis, FolderPlus } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { saveAssetToLibrary } from "@/cut/lib/library";
import { useEditor } from "@/cut/lib/store";
import type { MediaAsset } from "@/cut/lib/types";

/** The "…" menu on a generated asset (image tile, video job row, voiceover
 * row). Every surface gets the same pair — move the asset into the Media
 * panel (drop its `origin` tag) or copy it into the shared library — and
 * slots its own actions around them via `before`/`after`. */
export function GeneratedAssetMenu({
  asset,
  projectId,
  triggerClassName,
  before,
  after,
}: {
  asset: MediaAsset;
  projectId: string;
  triggerClassName: string;
  before?: ReactNode;
  after?: ReactNode;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label="More actions"
        title="More actions"
        className={triggerClassName}
      >
        <Ellipsis className="size-3.5" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-44">
        {before}
        {before != null && <DropdownMenuSeparator />}
        <DropdownMenuItem
          onClick={() =>
            // Clearing the origin files it into Media; a chat-owned asset also
            // sheds its thread so deleting the chat won't touch it.
            useEditor.getState().updateAsset(asset.id, { origin: undefined, chatId: undefined })
          }
        >
          <Clapperboard /> Add to Media
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() =>
            void saveAssetToLibrary(projectId, asset).catch(() => {
              // Library write failed; nothing to roll back.
            })
          }
        >
          <FolderPlus /> Add to library
        </DropdownMenuItem>
        {after != null && <DropdownMenuSeparator />}
        {after}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

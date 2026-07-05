"use client";

import { useEffect, useRef, useState } from "react";
import { Film, FolderOpen, Loader2, Music, Plus, Trash2, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  deleteFromLibrary,
  fetchLibrary,
  libraryMediaUrl,
  uploadToLibrary,
  type LibraryAsset,
} from "@/cut/lib/library";
import { formatTime } from "@/cut/lib/time";

export function LibraryView() {
  const [assets, setAssets] = useState<LibraryAsset[] | null>(null);
  const [uploading, setUploading] = useState(0);
  const [deleting, setDeleting] = useState<LibraryAsset | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void fetchLibrary().then(setAssets).catch(() => setAssets([]));
  }, []);

  const upload = async (files: FileList) => {
    const list = Array.from(files);
    setUploading((n) => n + list.length);
    for (const file of list) {
      try {
        const asset = await uploadToLibrary(file);
        setAssets((prev) => [asset, ...(prev ?? [])]);
      } catch {
        // Skip unreadable files; the rest of the batch still uploads.
      } finally {
        setUploading((n) => n - 1);
      }
    }
  };

  const remove = async () => {
    if (!deleting) return;
    await deleteFromLibrary(deleting.id);
    setAssets((prev) => (prev ?? []).filter((a) => a.id !== deleting.id));
    setDeleting(null);
  };

  return (
    <div className="mx-auto w-full max-w-6xl px-10 py-9">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight">Library</h1>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Clips and music you can drop into any project.
          </p>
        </div>
        <Button onClick={() => inputRef.current?.click()}>
          <Upload data-icon="inline-start" /> Add media
        </Button>
        <input
          ref={inputRef}
          type="file"
          accept="video/*,audio/*"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) void upload(e.target.files);
            e.target.value = "";
          }}
        />
      </div>

      {assets === null ? (
        <div className="grid place-items-center py-24 text-muted-foreground">
          <Loader2 className="size-5 animate-spin" />
        </div>
      ) : assets.length === 0 && uploading === 0 ? (
        <button
          className="grid w-full cursor-pointer place-items-center rounded-2xl border-2 border-dashed border-border py-24 transition-colors hover:border-primary/40"
          onClick={() => inputRef.current?.click()}
        >
          <div className="flex flex-col items-center gap-3 text-center">
            <FolderOpen className="size-8 text-muted-foreground" />
            <div className="text-base font-medium">Your library is empty</div>
            <p className="max-w-xs text-sm text-muted-foreground">
              Add intros, outros, logo stings, and music once — reuse them in
              every cut.
            </p>
          </div>
        </button>
      ) : (
        <div className="grid grid-cols-[repeat(auto-fill,minmax(160px,1fr))] gap-4">
          {assets.map((a) => (
            <LibraryCard key={a.id} asset={a} onDelete={() => setDeleting(a)} />
          ))}
          {uploading > 0 && (
            <div className="flex aspect-square flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-input text-xs text-muted-foreground">
              <Loader2 className="size-4 animate-spin" />
              Uploading…
            </div>
          )}
        </div>
      )}

      <AlertDialog open={!!deleting} onOpenChange={(o) => !o && setDeleting(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Remove “{deleting?.name}” from the library?</AlertDialogTitle>
            <AlertDialogDescription>
              Projects that already use it keep their own copy.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive/10 text-destructive hover:bg-destructive/20"
              onClick={(e) => {
                e.preventDefault();
                void remove();
              }}
            >
              Remove
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

export function LibraryCard({
  asset: a,
  onDelete,
  onUse,
}: {
  asset: LibraryAsset;
  onDelete?: () => void;
  onUse?: () => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [hovering, setHovering] = useState(false);

  return (
    <div
      className="group flex cursor-pointer flex-col gap-1.5"
      onMouseEnter={() => {
        if (a.type === "video") setHovering(true);
      }}
      onMouseLeave={() => {
        videoRef.current?.pause();
        setHovering(false);
      }}
      onClick={onUse}
    >
      <div className="relative aspect-square overflow-hidden rounded-xl border border-border bg-muted transition-shadow group-hover:shadow-[0_4px_20px_rgba(0,0,0,0.1)]">
        {a.type === "video" ? (
          <>
            <video
              src={`${libraryMediaUrl(a.fileName)}#t=0.1`}
              muted
              playsInline
              preload="metadata"
              className="size-full object-cover"
            />
            {hovering && (
              <video
                ref={videoRef}
                src={libraryMediaUrl(a.fileName)}
                autoPlay
                muted
                loop
                playsInline
                className="absolute inset-0 size-full object-cover"
              />
            )}
          </>
        ) : (
          <div className="grid size-full place-items-center bg-gradient-to-br from-emerald-100 to-emerald-50 text-emerald-600">
            <Music className="size-5" />
          </div>
        )}
        <span className="absolute right-1.5 bottom-1.5 rounded-md bg-black/65 px-1.5 py-0.5 font-mono text-[10px] text-white tabular-nums">
          {formatTime(a.duration)}
        </span>
        {onUse && (
          <span className="absolute top-1.5 left-1.5 grid size-5 scale-75 place-items-center rounded-full bg-primary text-primary-foreground opacity-0 transition-all group-hover:scale-100 group-hover:opacity-100">
            <Plus className="size-3" />
          </span>
        )}
        {onDelete && (
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Remove from library"
            className="absolute top-1.5 right-1.5 bg-black/40 text-white opacity-0 group-hover:opacity-100 hover:bg-black/60 hover:text-white"
            onClick={(e) => {
              e.stopPropagation();
              onDelete();
            }}
          >
            <Trash2 />
          </Button>
        )}
        {a.type === "video" && !hovering && (
          <span className="absolute bottom-1.5 left-1.5 text-white/90">
            <Film className="size-3.5 drop-shadow" />
          </span>
        )}
      </div>
      <div className="truncate px-0.5 text-xs text-muted-foreground">{a.name}</div>
    </div>
  );
}

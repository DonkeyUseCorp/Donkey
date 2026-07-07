"use client";

import { useEffect, useRef, useState } from "react";
import {
  Check,
  Film,
  Folder,
  FolderOpen,
  Link as LinkIcon,
  Loader2,
  Music,
  Plus,
  Trash2,
  Upload,
} from "lucide-react";
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
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { clearAssetDrag, setLibraryDragData } from "@/cut/lib/assetDrag";
import {
  createLibraryFolder,
  deleteFromLibrary,
  deleteLibraryFolder,
  fetchLibrary,
  importUrlToLibrary,
  libraryMediaUrl,
  moveLibraryAsset,
  renameLibraryFolder,
  uploadToLibrary,
  type LibraryAsset,
  type LibraryFolder,
} from "@/cut/lib/library";
import { formatTime } from "@/cut/lib/time";
import { cn } from "@/lib/utils";
import { buildDragGhost, FolderCrumb, FolderShelf, Marquee } from "./desktopFolders";

// A dragged library selection travels as a JSON array of asset ids, so a whole
// marquee-selected collection can be dropped onto a folder at once.
const LIBRARY_MOVE_MIME = "application/x-cut-library-move";

export function LibraryView() {
  const [assets, setAssets] = useState<LibraryAsset[] | null>(null);
  const [folders, setFolders] = useState<LibraryFolder[]>([]);
  const [openFolder, setOpenFolder] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [uploading, setUploading] = useState(0);
  const [addOpen, setAddOpen] = useState(false);
  const [importing, setImporting] = useState(false);
  const [url, setUrl] = useState("");
  const [urlError, setUrlError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<LibraryAsset | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const reload = () =>
    fetchLibrary()
      .then((d) => {
        setAssets(d.assets);
        setFolders(d.folders);
      })
      .catch(() => setAssets([]));

  useEffect(() => {
    void reload();
  }, []);

  const upload = async (files: FileList) => {
    const list = Array.from(files);
    setUploading((n) => n + list.length);
    for (const file of list) {
      try {
        const asset = await uploadToLibrary(file);
        if (openFolder) {
          await moveLibraryAsset(asset.id, openFolder).catch(() => {});
          asset.folderId = openFolder;
        }
        setAssets((prev) => [asset, ...(prev ?? [])]);
      } catch {
        // Skip unreadable files; the rest of the batch still uploads.
      } finally {
        setUploading((n) => n - 1);
      }
    }
  };

  const importUrl = async () => {
    const value = url.trim();
    if (!value || importing) return;
    setImporting(true);
    setUrlError(null);
    try {
      const asset = await importUrlToLibrary(value);
      if (openFolder) {
        await moveLibraryAsset(asset.id, openFolder).catch(() => {});
        asset.folderId = openFolder;
      }
      setAssets((prev) => [asset, ...(prev ?? [])]);
      setUrl("");
      setAddOpen(false);
    } catch (e) {
      setUrlError(e instanceof Error ? e.message : "Could not import that URL.");
    } finally {
      setImporting(false);
    }
  };

  const remove = async () => {
    if (!deleting) return;
    const id = deleting.id;
    setDeleting(null);
    setAssets((prev) => (prev ?? []).filter((a) => a.id !== id));
    try {
      await deleteFromLibrary(id);
    } catch {
      void reload();
    }
  };

  const moveAssets = async (ids: string[], folderId: string | null) => {
    if (ids.length === 0) return;
    const idset = new Set(ids);
    setAssets((prev) => (prev ?? []).map((a) => (idset.has(a.id) ? { ...a, folderId } : a)));
    setSelected(new Set());
    await Promise.all(ids.map((id) => moveLibraryAsset(id, folderId))).catch(() => void reload());
  };

  // Carry the current selection (or just this card) as a folder-move payload,
  // with a ghost — alongside the timeline-drag payload the card already sets.
  const onCardDragExtra = (e: React.DragEvent, a: LibraryAsset) => {
    const ids = selected.has(a.id) && selected.size > 0 ? Array.from(selected) : [a.id];
    if (!selected.has(a.id)) setSelected(new Set([a.id]));
    e.dataTransfer.setData(LIBRARY_MOVE_MIME, JSON.stringify(ids));
    e.dataTransfer.effectAllowed = "copyMove";
    const ghost = buildDragGhost(ids.length, ids.length > 1 ? `${ids.length} items` : a.name);
    document.body.appendChild(ghost);
    e.dataTransfer.setDragImage(ghost, 18, 16);
    setTimeout(() => ghost.remove(), 0);
  };

  const all = assets ?? [];
  const shown = all.filter((a) => (a.folderId ?? null) === openFolder);
  const openFolderName = folders.find((f) => f.id === openFolder)?.name;
  const hasContent = all.length > 0 || folders.length > 0;

  return (
    <div className="mx-auto w-full max-w-6xl px-10 py-9">
      <div className="mb-5 flex items-center justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold tracking-tight">Library</h1>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Clips and music you can drop into any project.
          </p>
        </div>
        <Button onClick={() => { setUrlError(null); setAddOpen(true); }}>
          <Upload data-icon="inline-start" /> Add media
        </Button>
        <input
          ref={inputRef}
          type="file"
          accept="video/*,audio/*"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) {
              void upload(e.target.files);
              setAddOpen(false);
            }
            e.target.value = "";
          }}
        />
      </div>

      {openFolder !== null ? (
        <div className="mb-5">
          <FolderCrumb
            root="Library"
            name={openFolderName ?? "Folder"}
            mime={LIBRARY_MOVE_MIME}
            onBack={() => {
              setSelected(new Set());
              setOpenFolder(null);
            }}
            onDropOut={(ids) => void moveAssets(ids, null)}
          />
        </div>
      ) : hasContent ? (
        <FolderShelf
          folders={folders}
          mime={LIBRARY_MOVE_MIME}
          statOf={(id) => ({ count: all.filter((a) => (a.folderId ?? null) === id).length })}
          onOpen={(id) => {
            setSelected(new Set());
            setOpenFolder(id);
          }}
          onCreate={async (name) => {
            const f = await createLibraryFolder(name);
            setFolders((prev) => [...prev, f]);
          }}
          onRename={async (id, name) => {
            setFolders((prev) => prev.map((f) => (f.id === id ? { ...f, name } : f)));
            await renameLibraryFolder(id, name).catch(() => void reload());
          }}
          onDelete={async (id) => {
            setFolders((prev) => prev.filter((f) => f.id !== id));
            setAssets((prev) =>
              (prev ?? []).map((a) => (a.folderId === id ? { ...a, folderId: null } : a))
            );
            if (openFolder === id) setOpenFolder(null);
            await deleteLibraryFolder(id).catch(() => void reload());
          }}
          onDropIds={(ids, fid) => void moveAssets(ids, fid)}
        />
      ) : null}

      {assets === null ? (
        <div className="grid place-items-center py-24 text-muted-foreground">
          <Loader2 className="size-5 animate-spin" />
        </div>
      ) : !hasContent ? (
        <button
          className="grid w-full cursor-pointer place-items-center rounded-2xl border-2 border-dashed border-border py-24 transition-colors hover:border-primary/40"
          onClick={() => {
            setUrlError(null);
            setAddOpen(true);
          }}
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
      ) : shown.length === 0 && uploading === 0 ? (
        <div className="grid place-items-center py-16 text-center text-sm text-muted-foreground">
          {openFolder === null ? "No media yet." : "Empty folder."}
        </div>
      ) : (
        <Marquee
          className="grid min-h-[40vh] grid-cols-[repeat(auto-fill,minmax(160px,1fr))] content-start gap-4"
          selected={selected}
          setSelected={setSelected}
        >
          {shown.map((a) => (
            <LibraryCard
              key={a.id}
              asset={a}
              folders={folders}
              selected={selected.has(a.id)}
              onDelete={() => setDeleting(a)}
              onMove={(folderId) => void moveAssets([a.id], folderId)}
              onDragStartExtra={(e) => onCardDragExtra(e, a)}
            />
          ))}
          {uploading > 0 && (
            <div className="flex aspect-square flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-input text-xs text-muted-foreground">
              <Loader2 className="size-4 animate-spin" />
              Uploading…
            </div>
          )}
        </Marquee>
      )}

      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Add media</DialogTitle>
          </DialogHeader>
          <div className="flex flex-col gap-4">
            <button
              className="flex flex-col items-center gap-2 rounded-xl border-2 border-dashed border-border py-8 transition-colors hover:border-primary/50 hover:bg-muted/40"
              onClick={() => inputRef.current?.click()}
            >
              <Upload className="size-6 text-muted-foreground" />
              <span className="text-sm font-medium">Choose files</span>
              <span className="text-xs text-muted-foreground">Video or audio from your Mac</span>
            </button>
            <div className="flex items-center gap-3 text-[11px] tracking-wide text-muted-foreground uppercase">
              <div className="h-px flex-1 bg-border" /> or paste a link{" "}
              <div className="h-px flex-1 bg-border" />
            </div>
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center gap-2">
                <div className="relative flex-1">
                  <LinkIcon className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
                  <Input
                    autoFocus
                    value={url}
                    placeholder="TikTok, YouTube, or Instagram link…"
                    className="pl-8"
                    onChange={(e) => setUrl(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") void importUrl();
                    }}
                  />
                </div>
                <Button disabled={!url.trim() || importing} onClick={() => void importUrl()}>
                  {importing ? <Loader2 className="animate-spin" /> : <LinkIcon />} Import
                </Button>
              </div>
              {urlError && <p className="text-xs text-destructive">{urlError}</p>}
            </div>
          </div>
        </DialogContent>
      </Dialog>

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
  folders,
  selected,
  onDelete,
  onUse,
  onMove,
  onDragStartExtra,
}: {
  asset: LibraryAsset;
  folders?: LibraryFolder[];
  selected?: boolean;
  onDelete?: () => void;
  onUse?: () => void;
  onMove?: (folderId: string | null) => void;
  onDragStartExtra?: (e: React.DragEvent) => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  // Poster from the video itself so the still matches what plays on hover.
  // An ffmpeg still washes out iPhone HDR (HLG) footage — the browser tone-maps
  // the video correctly, so we render the frame instead of a baked thumbnail.
  const posterT = Math.min(1, Math.max(0.1, (a.duration || 2) / 10));

  return (
    <div
      data-sel-id={a.id}
      className="group flex flex-col gap-1.5"
      draggable
      onDragStart={(e) => {
        setLibraryDragData(e, a);
        onDragStartExtra?.(e);
      }}
      onDragEnd={clearAssetDrag}
      onMouseEnter={() => void videoRef.current?.play().catch(() => {})}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = posterT;
        }
      }}
    >
      <div
        className={cn(
          "relative aspect-square cursor-grab overflow-hidden rounded-xl border bg-muted transition-shadow group-hover:shadow-[0_4px_20px_rgba(0,0,0,0.1)] active:cursor-grabbing",
          selected ? "border-primary ring-2 ring-primary" : "border-border"
        )}
      >
        {a.type === "video" ? (
          <video
            ref={videoRef}
            src={`${libraryMediaUrl(a.fileName)}#t=${posterT}`}
            muted
            loop
            playsInline
            preload="metadata"
            className="size-full object-cover"
          />
        ) : (
          <div className="grid size-full place-items-center bg-gradient-to-br from-emerald-100 to-emerald-50 text-emerald-600">
            <Music className="size-5" />
          </div>
        )}
        <span className="absolute right-1.5 bottom-1.5 rounded-md bg-black/65 px-1.5 py-0.5 font-mono text-[10px] text-white tabular-nums">
          {formatTime(a.duration)}
        </span>
        {onUse && (
          <button
            aria-label="Add to timeline"
            title="Add to timeline"
            className="absolute top-1.5 left-1.5 grid size-6 place-items-center rounded-full bg-primary text-primary-foreground opacity-0 shadow transition-all group-hover:opacity-100 hover:scale-110"
            onClick={(e) => {
              e.stopPropagation();
              onUse();
            }}
          >
            <Plus className="size-3.5" />
          </button>
        )}
        <div className="absolute top-1.5 right-1.5 flex gap-1 opacity-0 group-hover:opacity-100">
          {onMove && folders && (
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    aria-label="Move to folder"
                    title="Move to folder"
                    className="bg-black/40 text-white hover:bg-black/60 hover:text-white"
                  />
                }
              >
                <Folder />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onClick={() => onMove(null)}>
                  {(a.folderId ?? null) === null && <Check />} No folder
                </DropdownMenuItem>
                {folders.length > 0 && <DropdownMenuSeparator />}
                {folders.map((f) => (
                  <DropdownMenuItem key={f.id} onClick={() => onMove(f.id)}>
                    {a.folderId === f.id && <Check />} {f.name}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          )}
          {onDelete && (
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label="Remove from library"
              className="bg-black/40 text-white hover:bg-black/60 hover:text-white"
              onClick={(e) => {
                e.stopPropagation();
                onDelete();
              }}
            >
              <Trash2 />
            </Button>
          )}
        </div>
        {a.type === "video" && (
          <span className="absolute bottom-1.5 left-1.5 text-white/90">
            <Film className="size-3.5 drop-shadow" />
          </span>
        )}
      </div>
      <div className="truncate px-0.5 text-xs text-muted-foreground">{a.name}</div>
    </div>
  );
}

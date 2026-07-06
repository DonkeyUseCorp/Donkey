"use client";

import { useEffect, useRef, useState } from "react";
import {
  Check,
  Film,
  Folder,
  FolderOpen,
  FolderPlus,
  Link as LinkIcon,
  Loader2,
  MoreHorizontal,
  Music,
  Pencil,
  Plus,
  Trash2,
  Upload,
  X,
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
  libraryThumbUrl,
  moveLibraryAsset,
  renameLibraryFolder,
  uploadToLibrary,
  type LibraryAsset,
  type LibraryFolder,
} from "@/cut/lib/library";
import { formatTime } from "@/cut/lib/time";
import { cn } from "@/lib/utils";

export function LibraryView() {
  const [assets, setAssets] = useState<LibraryAsset[] | null>(null);
  const [folders, setFolders] = useState<LibraryFolder[]>([]);
  const [activeFolder, setActiveFolder] = useState<string | null>(null); // null = All
  const [uploading, setUploading] = useState(0);
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
        if (activeFolder) {
          await moveLibraryAsset(asset.id, activeFolder).catch(() => {});
          asset.folderId = activeFolder;
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
      if (activeFolder) {
        await moveLibraryAsset(asset.id, activeFolder).catch(() => {});
        asset.folderId = activeFolder;
      }
      setAssets((prev) => [asset, ...(prev ?? [])]);
      setUrl("");
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

  const move = async (assetId: string, folderId: string | null) => {
    setAssets((prev) =>
      (prev ?? []).map((a) => (a.id === assetId ? { ...a, folderId } : a))
    );
    await moveLibraryAsset(assetId, folderId).catch(() => void reload());
  };

  const shown = (assets ?? []).filter((a) =>
    activeFolder === null ? true : (a.folderId ?? null) === activeFolder
  );

  return (
    <div className="mx-auto w-full max-w-6xl px-10 py-9">
      <div className="mb-5 flex items-center justify-between gap-4">
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

      {/* Import from a URL (TikTok, YouTube, Instagram, …). */}
      <div className="mb-5 flex flex-col gap-1.5">
        <div className="flex items-center gap-2">
          <div className="relative flex-1">
            <LinkIcon className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={url}
              placeholder="Paste a TikTok, YouTube, or Instagram link…"
              className="pl-8"
              onChange={(e) => setUrl(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void importUrl();
              }}
            />
          </div>
          <Button variant="outline" disabled={!url.trim() || importing} onClick={() => void importUrl()}>
            {importing ? <Loader2 className="animate-spin" /> : <LinkIcon />} Import
          </Button>
        </div>
        {urlError && <p className="text-xs text-destructive">{urlError}</p>}
      </div>

      <FolderBar
        folders={folders}
        active={activeFolder}
        counts={countByFolder(assets ?? [])}
        onSelect={setActiveFolder}
        onCreate={async (name) => {
          const f = await createLibraryFolder(name);
          setFolders((prev) => [...prev, f]);
          setActiveFolder(f.id);
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
          if (activeFolder === id) setActiveFolder(null);
          await deleteLibraryFolder(id).catch(() => void reload());
        }}
      />

      {assets === null ? (
        <div className="grid place-items-center py-24 text-muted-foreground">
          <Loader2 className="size-5 animate-spin" />
        </div>
      ) : shown.length === 0 && uploading === 0 ? (
        <button
          className="grid w-full cursor-pointer place-items-center rounded-2xl border-2 border-dashed border-border py-24 transition-colors hover:border-primary/40"
          onClick={() => inputRef.current?.click()}
        >
          <div className="flex flex-col items-center gap-3 text-center">
            <FolderOpen className="size-8 text-muted-foreground" />
            <div className="text-base font-medium">
              {activeFolder ? "This folder is empty" : "Your library is empty"}
            </div>
            <p className="max-w-xs text-sm text-muted-foreground">
              Add intros, outros, logo stings, and music once — reuse them in
              every cut.
            </p>
          </div>
        </button>
      ) : (
        <div className="grid grid-cols-[repeat(auto-fill,minmax(160px,1fr))] gap-4">
          {shown.map((a) => (
            <LibraryCard
              key={a.id}
              asset={a}
              folders={folders}
              onDelete={() => setDeleting(a)}
              onMove={(folderId) => void move(a.id, folderId)}
            />
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

function countByFolder(assets: LibraryAsset[]): Map<string | null, number> {
  const m = new Map<string | null, number>();
  for (const a of assets) {
    const key = a.folderId ?? null;
    m.set(key, (m.get(key) ?? 0) + 1);
  }
  return m;
}

/** Folder chips: All + each folder, with create/rename/delete inline. */
function FolderBar({
  folders,
  active,
  counts,
  onSelect,
  onCreate,
  onRename,
  onDelete,
}: {
  folders: LibraryFolder[];
  active: string | null;
  counts: Map<string | null, number>;
  onSelect: (id: string | null) => void;
  onCreate: (name: string) => void | Promise<void>;
  onRename: (id: string, name: string) => void | Promise<void>;
  onDelete: (id: string) => void | Promise<void>;
}) {
  const [creating, setCreating] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [draft, setDraft] = useState("");

  const chip = (label: string, count: number | undefined, selected: boolean, onClick: () => void) => (
    <button
      className={cn(
        "flex shrink-0 items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors",
        selected
          ? "border-primary bg-primary/10 text-primary"
          : "border-border text-muted-foreground hover:text-foreground"
      )}
      onClick={onClick}
    >
      {label}
      {count ? <span className="tabular-nums opacity-60">{count}</span> : null}
    </button>
  );

  return (
    <div className="mb-5 flex flex-wrap items-center gap-2">
      {chip("All", undefined, active === null, () => onSelect(null))}
      {folders.map((f) =>
        editingId === f.id ? (
          <span key={f.id} className="flex items-center gap-1">
            <Input
              autoFocus
              value={draft}
              className="h-7 w-32 text-xs"
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && draft.trim()) {
                  void onRename(f.id, draft.trim());
                  setEditingId(null);
                } else if (e.key === "Escape") setEditingId(null);
              }}
            />
            <Button
              size="icon-sm"
              variant="ghost"
              onClick={() => {
                if (draft.trim()) void onRename(f.id, draft.trim());
                setEditingId(null);
              }}
            >
              <Check />
            </Button>
          </span>
        ) : (
          <span key={f.id} className="group/chip flex items-center gap-0.5">
            <button
              className={cn(
                "flex shrink-0 items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors",
                active === f.id
                  ? "border-primary bg-primary/10 text-primary"
                  : "border-border text-muted-foreground hover:text-foreground"
              )}
              onClick={() => onSelect(f.id)}
              onDoubleClick={() => {
                setDraft(f.name);
                setEditingId(f.id);
              }}
            >
              <Folder className="size-3" />
              {f.name}
              {counts.get(f.id) ? (
                <span className="tabular-nums opacity-60">{counts.get(f.id)}</span>
              ) : null}
            </button>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label="Folder options"
                    className="size-6 text-muted-foreground opacity-0 group-hover/chip:opacity-100"
                  />
                }
              >
                <MoreHorizontal className="size-3.5" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start">
                <DropdownMenuItem
                  onClick={() => {
                    setDraft(f.name);
                    setEditingId(f.id);
                  }}
                >
                  <Pencil /> Rename
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem variant="destructive" onClick={() => void onDelete(f.id)}>
                  <Trash2 /> Delete folder
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </span>
        )
      )}

      {creating ? (
        <span className="flex items-center gap-1">
          <Input
            autoFocus
            value={draft}
            placeholder="Folder name"
            className="h-7 w-32 text-xs"
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && draft.trim()) {
                void onCreate(draft.trim());
                setDraft("");
                setCreating(false);
              } else if (e.key === "Escape") setCreating(false);
            }}
          />
          <Button size="icon-sm" variant="ghost" onClick={() => setCreating(false)}>
            <X />
          </Button>
        </span>
      ) : (
        <button
          className="flex shrink-0 items-center gap-1 rounded-full border border-dashed border-border px-3 py-1 text-xs text-muted-foreground transition-colors hover:text-foreground"
          onClick={() => {
            setDraft("");
            setCreating(true);
          }}
        >
          <FolderPlus className="size-3.5" /> New folder
        </button>
      )}
    </div>
  );
}

export function LibraryCard({
  asset: a,
  folders,
  onDelete,
  onUse,
  onMove,
}: {
  asset: LibraryAsset;
  folders?: LibraryFolder[];
  onDelete?: () => void;
  onUse?: () => void;
  onMove?: (folderId: string | null) => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [hovering, setHovering] = useState(false);

  return (
    <div
      className="group flex flex-col gap-1.5"
      draggable
      onDragStart={(e) => setLibraryDragData(e, a)}
      onDragEnd={clearAssetDrag}
      onMouseEnter={() => {
        if (a.type === "video") setHovering(true);
      }}
      onMouseLeave={() => {
        videoRef.current?.pause();
        setHovering(false);
      }}
    >
      <div className="relative aspect-square cursor-grab overflow-hidden rounded-xl border border-border bg-muted transition-shadow group-hover:shadow-[0_4px_20px_rgba(0,0,0,0.1)] active:cursor-grabbing">
        {a.type === "video" ? (
          <>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={libraryThumbUrl(a.id)}
              alt=""
              loading="lazy"
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

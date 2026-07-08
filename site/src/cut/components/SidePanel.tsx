"use client";

import { useEffect, useRef, useState } from "react";
import { Captions, Check, Circle, ClipboardList, Copy, Film, FolderOpen, FolderPlus, Layers, Loader2, Mic, Music, Plus, Trash2, Upload, Video } from "lucide-react";
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
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { apiFetch, apiUrl } from "@/cut/lib/api";
import { clearAssetDrag, setAssetDragData } from "@/cut/lib/assetDrag";
import { deleteExport, revealExport } from "@/cut/lib/exportClient";
import { useExport } from "@/cut/lib/exportStore";
import {
  addLibraryAssetToProject,
  addTemplateToProject,
  createLibraryFolder,
  deleteFromLibrary,
  deleteLibraryFolder,
  deleteTemplate,
  fetchLibrary,
  moveLibraryAsset,
  renameLibraryFolder,
  saveAssetToLibrary,
  type LibraryAsset,
  type LibraryFolder,
} from "@/cut/lib/library";
import type { LibraryTemplate } from "@/cut/lib/types";
import { CAPTION_LIMIT, normalizeTags } from "@/cut/lib/publish";
import { useEditor } from "@/cut/lib/store";
import { formatTime } from "@/cut/lib/time";
import type { MediaAsset } from "@/cut/lib/types";
import { cn } from "@/lib/utils";
import { buildDragGhost, FolderCrumb, FolderShelf } from "./desktopFolders";
import { LibraryCard } from "./LibraryView";

// Drag a library clip onto a folder tile to file it (side panel, single card).
const LIBRARY_MOVE_MIME = "application/x-cut-library-move";
import { PlatformPreviewDialog, type ExportItem } from "./PlatformPreview";
import { RecordDialog, type RecordMode } from "./RecordDialog";
import { SubtitlesPanel } from "./SubtitlesPanel";

type Tab = "media" | "library" | "record" | "subtitles" | "publish";

const TABS: { id: Tab; label: string; icon: typeof Film }[] = [
  { id: "media", label: "Media", icon: Film },
  { id: "library", label: "Library", icon: FolderOpen },
  { id: "record", label: "Record", icon: Circle },
  { id: "subtitles", label: "Subtitles", icon: Captions },
  { id: "publish", label: "Details", icon: ClipboardList },
];

export function SidePanel({
  projectId,
  onImport,
  importing,
}: {
  projectId: string;
  onImport: (files: FileList | File[]) => void;
  importing: boolean;
}) {
  const [tab, setTab] = useState<Tab>("media");
  const [recordMode, setRecordMode] = useState<RecordMode | null>(null);

  return (
    <div className="flex min-h-0 border-r border-border bg-card">
      {/* Icon rail */}
      <div className="flex w-[68px] shrink-0 flex-col items-center gap-1 border-r border-border py-3">
        {TABS.map(({ id, label, icon: Icon }) => {
          const tileClass =
            "flex flex-col items-center gap-1 rounded-lg px-2 py-1.5 text-muted-foreground transition-colors hover:text-foreground";
          const inner = (
            <>
              <span
                className={cn(
                  "grid size-9 place-items-center rounded-lg transition-colors",
                  tab === id ? "bg-muted text-foreground" : "hover:bg-muted/60"
                )}
              >
                <Icon className="size-4.5" />
              </span>
              <span className={cn("text-[10px] font-medium", tab === id && "text-foreground")}>
                {label}
              </span>
            </>
          );

          if (id === "record") {
            return (
              <DropdownMenu key={id}>
                <DropdownMenuTrigger render={<button className={tileClass} />}>
                  {inner}
                </DropdownMenuTrigger>
                <DropdownMenuContent
                  align="start"
                  side="right"
                  style={{ width: "12rem" }}
                >
                  <DropdownMenuItem onClick={() => setRecordMode("camera")}>
                    <Video /> Record camera
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => setRecordMode("audio")}>
                    <Mic /> Record audio
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            );
          }

          return (
            <button
              key={id}
              className={tileClass}
              aria-pressed={tab === id}
              onClick={() => setTab(id)}
            >
              {inner}
            </button>
          );
        })}
      </div>

      <div className="flex w-[264px] min-h-0 shrink-0 flex-col">
        {tab === "media" && (
          <MediaPanel projectId={projectId} onImport={onImport} importing={importing} />
        )}
        {tab === "library" && <LibraryPanel projectId={projectId} />}
        {tab === "subtitles" && <SubtitlesPanel />}
        {tab === "publish" && <PublishPanel />}
      </div>
      {recordMode && (
        <RecordDialog
          mode={recordMode}
          onClose={() => setRecordMode(null)}
          onUse={(file) => onImport([file])}
        />
      )}
    </div>
  );
}

function PanelHead({ title, action }: { title: string; action?: React.ReactNode }) {
  return (
    <div className="flex h-12 shrink-0 items-center justify-between pr-2.5 pl-4">
      <span className="text-sm font-semibold tracking-tight">{title}</span>
      {action}
    </div>
  );
}

function MediaPanel({
  projectId,
  onImport,
  importing,
}: {
  projectId: string;
  onImport: (files: FileList) => void;
  importing: boolean;
}) {
  const assets = useEditor((s) => s.assets);
  const exportOpen = useEditor((s) => s.exportOpen);
  // A render that finishes in the background (dialog closed) drops a new file in
  // the exports folder; re-read the list when it lands so it shows without a
  // manual refresh.
  const exportStatus = useExport((s) => s.status);
  const inputRef = useRef<HTMLInputElement>(null);
  const [exports, setExports] = useState<ExportItem[]>([]);
  const [preview, setPreview] = useState<ExportItem | null>(null);
  const [deletingExport, setDeletingExport] = useState<ExportItem | null>(null);

  // Refresh the list on open, when the export dialog closes, and when a
  // background render settles (done/error).
  useEffect(() => {
    if (exportOpen) return;
    let alive = true;
    void apiFetch(`/api/cut/projects/${projectId}/exports`)
      .then((r) => (r.ok ? (r.json() as Promise<ExportItem[]>) : []))
      .then((list) => alive && setExports(list))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [projectId, exportOpen, exportStatus]);

  const removeExport = async () => {
    const it = deletingExport;
    if (!it) return;
    setDeletingExport(null);
    try {
      await deleteExport(projectId, it.file);
    } catch {
      // Fall through and re-read the folder so the list mirrors disk truth
      // (a failed delete stays visible rather than reappearing later).
    }
    const list = await apiFetch(`/api/cut/projects/${projectId}/exports`)
      .then((r) => (r.ok ? (r.json() as Promise<ExportItem[]>) : []))
      .catch(() => [] as ExportItem[]);
    setExports(list);
    if (preview && !list.some((e) => e.file === preview.file)) setPreview(null);
  };

  return (
    <>
      <PanelHead title="Media" />
      <div className="px-3.5 pb-3">
        <Button variant="outline" className="w-full" onClick={() => inputRef.current?.click()}>
          <Upload data-icon="inline-start" /> Upload
        </Button>
        <input
          ref={inputRef}
          type="file"
          accept="video/*,audio/*"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) onImport(e.target.files);
            e.target.value = "";
          }}
        />
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto pb-3.5">
        {assets.length === 0 && !importing ? (
          <div className="mx-3.5 rounded-xl border-[1.5px] border-dashed border-input px-4 py-7 text-center text-xs leading-relaxed text-muted-foreground">
            <div className="mb-3 flex justify-center gap-3.5">
              <Film className="size-5" />
              <Music className="size-5" />
            </div>
            Drop videos and music anywhere, or upload to this project.
          </div>
        ) : (
          <div className="grid grid-cols-2 content-start gap-2.5 px-3.5">
            {assets.map((a) => (
              <AssetCard key={a.id} asset={a} projectId={projectId} />
            ))}
            {importing && (
              <div className="flex aspect-square flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-input text-[11px] text-muted-foreground">
                <Loader2 className="size-4 animate-spin" />
                Importing…
              </div>
            )}
          </div>
        )}

        {exports.length > 0 && (
          <div className="mt-5 px-3.5">
            <div className="mb-2 text-[13px] font-semibold tracking-tight">Exports</div>
            <div className="flex flex-col gap-1.5">
              {exports.map((it) => (
                <div
                  key={it.file}
                  className="export-row group flex w-full items-center gap-2.5 rounded-lg border border-border p-1.5 transition-colors hover:border-input hover:bg-muted/50"
                >
                  <button
                    type="button"
                    className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
                    title="Preview as a post"
                    onClick={() => setPreview(it)}
                  >
                    <video
                      muted
                      playsInline
                      preload="metadata"
                      src={`${apiUrl(`/api/cut/projects/${projectId}/exports/${encodeURIComponent(it.file)}`)}#t=0.1`}
                      className="h-11 w-[25px] shrink-0 rounded-[4px] bg-black object-cover"
                    />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[11.5px] font-medium">
                        {new Date(it.mtime).toLocaleString([], {
                          month: "short",
                          day: "numeric",
                          hour: "numeric",
                          minute: "2-digit",
                        })}
                      </span>
                      <span className="block text-[10.5px] text-muted-foreground">
                        {(it.size / (1024 * 1024)).toFixed(1)} MB · MP4
                      </span>
                    </span>
                  </button>
                  <div className="flex shrink-0 items-center gap-0.5 pr-0.5 opacity-0 transition-opacity group-hover:opacity-100">
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-label="Show in Finder"
                      title="Show in Finder"
                      onClick={() => void revealExport(projectId, it.file).catch(() => {})}
                    >
                      <FolderOpen />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-label="Delete export"
                      title="Delete export"
                      className="text-muted-foreground hover:text-destructive"
                      onClick={() => setDeletingExport(it)}
                    >
                      <Trash2 />
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
      {preview && (
        <PlatformPreviewDialog
          projectId={projectId}
          item={preview}
          onClose={() => setPreview(null)}
        />
      )}

      <AlertDialog open={!!deletingExport} onOpenChange={(o) => !o && setDeletingExport(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this export?</AlertDialogTitle>
            <AlertDialogDescription>
              The rendered file leaves the project’s exports folder. Your cut is untouched — you
              can export it again anytime.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive/10 text-destructive hover:bg-destructive/20"
              onClick={(e) => {
                e.preventDefault();
                void removeExport();
              }}
            >
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

function AssetCard({ asset, projectId }: { asset: MediaAsset; projectId: string }) {
  const [saved, setSaved] = useState(false);
  // Number of timeline items that would be cascade-deleted; null = no prompt.
  const [confirmUses, setConfirmUses] = useState<number | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);

  const add = () => {
    const s = useEditor.getState();
    if (asset.type === "video") s.addClipFromAsset(asset.id);
    else s.addAudioFromAsset(asset.id);
  };

  const saveToLibrary = async (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await saveAssetToLibrary(projectId, asset);
      setSaved(true);
      setTimeout(() => setSaved(false), 1800);
    } catch {
      // Library write failed; nothing to roll back.
    }
  };

  const remove = (e: React.MouseEvent) => {
    e.stopPropagation();
    const s = useEditor.getState();
    const uses =
      s.clips.filter((c) => c.assetId === asset.id).length +
      s.audioClips.filter((c) => c.assetId === asset.id).length;
    // Deleting an unused asset is harmless; only confirm when it would also
    // remove clips from the timeline.
    if (uses > 0) setConfirmUses(uses);
    else s.removeAsset(asset.id);
  };

  return (
    <>
    <div
      className="asset-card group flex flex-col gap-1.5 text-left"
      title="Drag onto the timeline, or click + to add"
      draggable
      onDragStart={(e) => setAssetDragData(e, asset.id)}
      onDragEnd={clearAssetDrag}
      onMouseEnter={() => {
        void videoRef.current?.play().catch(() => {});
      }}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = 0.1;
        }
      }}
    >
      <div className="relative aspect-square overflow-hidden rounded-lg border border-border bg-muted transition-colors group-hover:border-input">
        {asset.type === "video" ? (
          // Native first frame as the poster — full-resolution, no blurry thumb.
          <video
            ref={videoRef}
            src={`${asset.url}#t=0.1`}
            preload="metadata"
            muted
            loop
            playsInline
            className="size-full object-cover"
          />
        ) : (
          <div className="grid size-full place-items-center bg-gradient-to-br from-emerald-100 to-emerald-50 text-emerald-600">
            <Music className="size-4.5" />
          </div>
        )}
        <span className="absolute right-1 bottom-1 rounded-[5px] bg-black/65 px-1 py-px font-mono text-[9.5px] text-white tabular-nums">
          {formatTime(asset.duration)}
        </span>
        <span className="absolute top-1 left-1 flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
          <span
            role="button"
            title="Add to timeline"
            className="grid size-5 scale-75 cursor-pointer place-items-center rounded-full bg-primary text-primary-foreground transition-transform group-hover:scale-100 hover:brightness-110"
            onClick={(e) => {
              e.stopPropagation();
              add();
            }}
          >
            <Plus className="size-3" />
          </span>
        </span>
        <span className="absolute top-1 right-1 flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
          <span
            role="button"
            title="Save to library for reuse"
            className="grid size-5 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
            onClick={saveToLibrary}
          >
            {saved ? <Check className="size-3" /> : <FolderPlus className="size-3" />}
          </span>
          <span
            role="button"
            title="Remove from project"
            className="grid size-5 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
            onClick={remove}
          >
            <Trash2 className="size-3" />
          </span>
        </span>
      </div>
      <div className="truncate text-[11px] text-muted-foreground">{asset.name}</div>
    </div>
    <AlertDialog open={confirmUses !== null} onOpenChange={(o) => !o && setConfirmUses(null)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Remove “{asset.name}” from the project?</AlertDialogTitle>
          <AlertDialogDescription>
            It’s used by {confirmUses} {confirmUses === 1 ? "clip" : "clips"} on the timeline,
            which will be removed too. This can be undone with ⌘Z.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction
            className="bg-destructive/10 text-destructive hover:bg-destructive/20"
            onClick={(e) => {
              e.preventDefault();
              useEditor.getState().removeAsset(asset.id);
              setConfirmUses(null);
            }}
          >
            Remove
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
    </>
  );
}

function LibraryPanel({ projectId }: { projectId: string }) {
  const [assets, setAssets] = useState<LibraryAsset[] | null>(null);
  const [folders, setFolders] = useState<LibraryFolder[]>([]);
  const [templates, setTemplates] = useState<LibraryTemplate[]>([]);
  const [openFolder, setOpenFolder] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<LibraryAsset | null>(null);

  const reload = () =>
    fetchLibrary()
      .then((d) => {
        setAssets(d.assets);
        setFolders(d.folders);
        setTemplates(d.templates);
      })
      .catch(() => setAssets([]));

  const removeTemplate = async (id: string) => {
    setTemplates((prev) => prev.filter((t) => t.id !== id));
    await deleteTemplate(id).catch(() => void reload());
  };

  useEffect(() => {
    void reload();
  }, []);

  const remove = async () => {
    if (!deleting) return;
    const id = deleting.id;
    setAssets((prev) => (prev ?? []).filter((a) => a.id !== id));
    setDeleting(null);
    try {
      await deleteFromLibrary(id);
    } catch {
      // Server delete failed; pull a fresh list so the UI stays truthful.
      void reload();
    }
  };

  const move = async (assetId: string, folderId: string | null) => {
    setAssets((prev) => (prev ?? []).map((a) => (a.id === assetId ? { ...a, folderId } : a)));
    await moveLibraryAsset(assetId, folderId).catch(() => void reload());
  };

  // Let a clip be dragged onto a folder tile to file it (alongside the timeline
  // drag payload the card already sets).
  const onCardDragExtra = (e: React.DragEvent, a: LibraryAsset) => {
    e.dataTransfer.setData(LIBRARY_MOVE_MIME, JSON.stringify([a.id]));
    e.dataTransfer.effectAllowed = "copyMove";
    const ghost = buildDragGhost(1, a.name);
    document.body.appendChild(ghost);
    e.dataTransfer.setDragImage(ghost, 18, 16);
    setTimeout(() => ghost.remove(), 0);
  };

  const all = assets ?? [];
  const shown = all.filter((a) => (a.folderId ?? null) === openFolder);
  const openFolderName = folders.find((f) => f.id === openFolder)?.name;

  return (
    <>
      <PanelHead title="Library" />
      {templates.length > 0 && (
        <div className="shrink-0 px-3.5 pb-3">
          <div className="mb-1.5 text-[11px] font-semibold text-muted-foreground">Templates</div>
          <div className="flex flex-col gap-1.5">
            {templates.map((t) => (
              <div
                key={t.id}
                className="group flex items-center gap-2 rounded-lg border border-border bg-background px-2.5 py-1.5"
              >
                <Layers className="size-3.5 shrink-0 text-violet-500" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[12px] font-medium">{t.name}</div>
                  <div className="text-[10.5px] text-muted-foreground">
                    {formatTime(t.duration)} · {t.media.length + t.layers.length + t.audio.length} parts
                  </div>
                </div>
                <button
                  title="Add to this project"
                  className="grid size-6 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground hover:brightness-110"
                  onClick={() => void addTemplateToProject(projectId, t)}
                >
                  <Plus className="size-3.5" />
                </button>
                <button
                  title="Delete template"
                  className="grid size-6 shrink-0 place-items-center rounded-full text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:text-foreground"
                  onClick={() => void removeTemplate(t.id)}
                >
                  <Trash2 className="size-3.5" />
                </button>
              </div>
            ))}
          </div>
        </div>
      )}
      {openFolder !== null ? (
        <div className="shrink-0 px-3.5 pb-2.5">
          <FolderCrumb
            root="Library"
            name={openFolderName ?? "Folder"}
            mime={LIBRARY_MOVE_MIME}
            onBack={() => setOpenFolder(null)}
            onDropOut={(ids) => ids.forEach((id) => void move(id, null))}
          />
        </div>
      ) : all.length > 0 || folders.length > 0 ? (
        <div className="shrink-0 px-3.5">
          <FolderShelf
            folders={folders}
            mime={LIBRARY_MOVE_MIME}
            statOf={(id) => ({ count: all.filter((a) => (a.folderId ?? null) === id).length })}
            onOpen={(id) => setOpenFolder(id)}
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
            onDropIds={(ids, fid) => ids.forEach((id) => void move(id, fid))}
          />
        </div>
      ) : null}
      {assets === null ? (
        <div className="grid flex-1 place-items-center text-muted-foreground">
          <Loader2 className="size-4 animate-spin" />
        </div>
      ) : shown.length === 0 ? null : (
        <div className="grid min-h-0 flex-1 grid-cols-2 content-start gap-2.5 overflow-y-auto px-3.5 pb-3.5">
          {shown.map((a) => (
            <LibraryCard
              key={a.id}
              asset={a}
              folders={folders}
              onUse={() => void addLibraryAssetToProject(projectId, a)}
              onDelete={() => setDeleting(a)}
              onMove={(folderId) => void move(a.id, folderId)}
              onDragStartExtra={(e) => onCardDragExtra(e, a)}
            />
          ))}
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
    </>
  );
}

function CopyChip({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="copy-chip inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[10.5px] font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground disabled:opacity-40"
      disabled={!text}
      title={`Copy ${label}`}
      onClick={() => {
        void navigator.clipboard.writeText(text).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        });
      }}
    >
      {copied ? <Check className="size-3 text-emerald-600" /> : <Copy className="size-3" />}
      {copied ? "Copied" : "Copy"}
    </button>
  );
}

function PublishPanel() {
  const publish = useEditor((s) => s.publish);
  const setPublish = useEditor((s) => s.setPublish);
  const notes = useEditor((s) => s.notes);
  const setNotes = useEditor((s) => s.setNotes);
  const tagsLine = normalizeTags(publish.tags);
  const combined = [publish.caption.trim(), tagsLine].filter(Boolean).join("\n\n");
  const count = combined.length;
  const [copiedAll, setCopiedAll] = useState(false);

  const field = "text-[11px] font-semibold tracking-wider text-muted-foreground uppercase";

  return (
    <>
      <PanelHead title="Details" />
      <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-3.5 pb-4">
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between">
            <span className={field}>Caption</span>
            <CopyChip text={publish.caption.trim()} label="caption" />
          </div>
          <textarea
            className="publish-caption min-h-[110px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none focus:border-ring"
            placeholder={"What's happening in this video?\n\nHooks read best in the first line."}
            value={publish.caption}
            onChange={(e) => setPublish({ caption: e.target.value })}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between">
            <span className={field}>Tags</span>
            <CopyChip text={tagsLine} label="tags" />
          </div>
          <input
            className="publish-tags w-full rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] outline-none focus:border-ring"
            placeholder="fyp howto cut"
            value={publish.tags}
            onChange={(e) => setPublish({ tags: e.target.value })}
          />
          {tagsLine && (
            <div className="publish-tag-preview flex flex-wrap gap-1">
              {tagsLine.split(" ").map((t) => (
                <span key={t} className="rounded-md bg-muted px-1.5 py-0.5 font-mono text-[10.5px]">
                  {t}
                </span>
              ))}
            </div>
          )}
          <p className="text-[11px] leading-relaxed text-muted-foreground">
            3–5 focused tags work best. Tags count toward the caption limit.
          </p>
        </div>

        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between">
            <span className={field}>Sound title</span>
            <CopyChip text={publish.soundTitle.trim()} label="sound title" />
          </div>
          <input
            className="publish-sound w-full rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] outline-none focus:border-ring"
            placeholder="My track — artist"
            value={publish.soundTitle}
            onChange={(e) => setPublish({ soundTitle: e.target.value })}
          />
          <p className="text-[11px] leading-relaxed text-muted-foreground">
            TikTok names uploads “original sound – you”. You can rename the
            sound once after posting — paste this then.
          </p>
        </div>

        <div className="flex flex-col gap-1.5 border-t border-border pt-4">
          <span className={field}>Notes</span>
          <label className="flex items-center justify-between gap-2 text-[12px] text-muted-foreground">
            Published
            <input
              type="date"
              className="notes-date rounded-lg border border-input bg-transparent px-2 py-1 text-[12px] outline-none focus:border-ring"
              value={notes.publishedAt}
              onChange={(e) => setNotes({ publishedAt: e.target.value })}
            />
          </label>
          <textarea
            className="notes-links min-h-[54px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 font-mono text-[11.5px] leading-relaxed outline-none focus:border-ring"
            placeholder={"Links, one per line\nhttps://tiktok.com/…"}
            value={notes.links.join("\n")}
            onChange={(e) => setNotes({ links: e.target.value.split("\n") })}
          />
          <textarea
            className="notes-text min-h-[70px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none focus:border-ring"
            placeholder="Anything worth remembering about this cut…"
            value={notes.text}
            onChange={(e) => setNotes({ text: e.target.value })}
          />
        </div>

        <div className="mt-1 flex flex-col gap-2">
          <Button
            className="w-full"
            disabled={!combined}
            onClick={() => {
              void navigator.clipboard.writeText(combined).then(() => {
                setCopiedAll(true);
                setTimeout(() => setCopiedAll(false), 1500);
              });
            }}
          >
            {copiedAll ? (
              <>
                <Check data-icon="inline-start" /> Copied
              </>
            ) : (
              <>
                <Copy data-icon="inline-start" /> Copy caption + tags
              </>
            )}
          </Button>
          <p
            className={cn(
              "publish-count text-right font-mono text-[11px] tabular-nums",
              count > CAPTION_LIMIT ? "font-semibold text-red-600" : "text-muted-foreground"
            )}
          >
            {count.toLocaleString()} / {CAPTION_LIMIT.toLocaleString()}
          </p>
        </div>
      </div>
    </>
  );
}

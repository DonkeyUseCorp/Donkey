"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  Check,
  Copy,
  Film,
  Folder,
  LayoutGrid,
  List,
  Loader2,
  MoreHorizontal,
  Pencil,
  Plus,
  Trash2,
  Unplug,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { apiFetch, apiUrl } from "@/cut/lib/api";
import { createProjectFromFile, isMediaFile } from "@/cut/lib/media";
import { projectHref, useCutBase } from "@/cut/lib/nav";
import { formatTime } from "@/cut/lib/time";
import { mediaUrl, type ProjectFolder, type ProjectSummary } from "@/cut/lib/types";
import { cn } from "@/lib/utils";
import { buildDragGhost, FolderCrumb, FolderShelf, Marquee } from "./desktopFolders";

type View = "gallery" | "list";

// A dragged selection is carried as a JSON array of project ids, so one drag can
// move a whole marquee-selected collection into a folder.
const PROJECT_MIME = "application/x-cut-project";

function formatDate(ts: number) {
  const d = new Date(ts);
  const now = Date.now();
  const mins = Math.floor((now - ts) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  if (mins < 60 * 24) return `${Math.floor(mins / 60)}h ago`;
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(d.getFullYear() !== new Date().getFullYear() ? { year: "numeric" } : {}),
  });
}

export function ProjectsHome() {
  const router = useRouter();
  const base = useCutBase();
  const [projects, setProjects] = useState<ProjectSummary[] | null>(null);
  const [folders, setFolders] = useState<ProjectFolder[]>([]);
  const [openFolder, setOpenFolder] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [view, setView] = useState<View>("gallery");
  const [createOpen, setCreateOpen] = useState(false);
  const [renaming, setRenaming] = useState<ProjectSummary | null>(null);
  const [deleting, setDeleting] = useState<ProjectSummary | null>(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [engineDown, setEngineDown] = useState(false);
  // A count of desktop files still uploading into fresh projects, plus whether an
  // OS-file drag is hovering the surface (a depth counter tames enter/leave noise
  // as the cursor crosses child tiles).
  const [importing, setImporting] = useState(0);
  const [fileOver, setFileOver] = useState(false);
  const dragDepth = useRef(0);

  useEffect(() => {
    const saved = localStorage.getItem("cut-projects-view");
    if (saved === "list" || saved === "gallery") setView(saved);
  }, []);

  const switchView = (v: View) => {
    setView(v);
    localStorage.setItem("cut-projects-view", v);
  };

  const refresh = useCallback(async () => {
    try {
      const [res, fres] = await Promise.all([
        apiFetch("/api/cut/projects"),
        apiFetch("/api/cut/projects/folders"),
      ]);
      if (!res.ok) throw new Error(String(res.status));
      setProjects((await res.json()) as ProjectSummary[]);
      setFolders(fres.ok ? ((await fres.json()) as ProjectFolder[]) : []);
      setEngineDown(false);
    } catch {
      // The engine on this Mac isn't reachable — not running, or the page was
      // loaded from the hosted domain before starting it locally.
      setEngineDown(true);
    }
  }, []);

  const createFolder = async (fname: string) => {
    const res = await apiFetch("/api/cut/projects/folders", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: fname }),
    });
    if (res.ok) {
      const f = (await res.json()) as ProjectFolder;
      setFolders((prev) => [...prev, f]);
    }
  };

  const renameFolder = async (id: string, fname: string) => {
    setFolders((prev) => prev.map((f) => (f.id === id ? { ...f, name: fname } : f)));
    await apiFetch(`/api/cut/projects/folders/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: fname }),
    }).catch(() => void refresh());
  };

  const deleteFolder = async (id: string) => {
    setFolders((prev) => prev.filter((f) => f.id !== id));
    setProjects((prev) => (prev ?? []).map((p) => (p.folderId === id ? { ...p, folderId: null } : p)));
    if (openFolder === id) setOpenFolder(null);
    await apiFetch(`/api/cut/projects/folders/${id}`, { method: "DELETE" }).catch(() => void refresh());
  };

  // Move a collection of projects into a folder (or out to the root, folderId
  // null). Optimistic; reconciles from disk on any failure.
  const moveProjects = useCallback(
    async (ids: string[], folderId: string | null) => {
      if (ids.length === 0) return;
      const idset = new Set(ids);
      setProjects((prev) => (prev ?? []).map((p) => (idset.has(p.id) ? { ...p, folderId } : p)));
      setSelected(new Set());
      await Promise.all(
        ids.map((id) =>
          apiFetch(`/api/cut/projects/${id}/move`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ folderId }),
          })
        )
      ).catch(() => void refresh());
    },
    [refresh]
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // While the engine is unreachable, keep probing so the page springs to life
  // the moment it starts.
  useEffect(() => {
    if (!engineDown) return;
    const t = setInterval(() => void refresh(), 3000);
    return () => clearInterval(t);
  }, [engineDown, refresh]);

  const create = async () => {
    setBusy(true);
    try {
      const res = await apiFetch("/api/cut/projects", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim() || "Untitled", folderId: openFolder }),
      });
      const project = (await res.json()) as ProjectSummary;
      router.push(projectHref(base, project.id, "projects"));
    } finally {
      setBusy(false);
    }
  };

  // Make a new project in the folder that's open (root when none), then jump
  // straight into it — no naming step.
  const newProjectHere = async (folderId: string | null = openFolder) => {
    const res = await apiFetch("/api/cut/projects", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "Untitled", folderId }),
    });
    const project = (await res.json()) as ProjectSummary;
    router.push(projectHref(base, project.id, "projects"));
  };

  // Turn a batch of desktop files into projects filed under `folderId`. Each
  // becomes its own project and pops into the grid the moment it's ready.
  const importFilesAsProjects = useCallback(
    async (files: FileList | File[], folderId: string | null) => {
      const media = Array.from(files).filter(isMediaFile);
      if (media.length === 0) return;
      setImporting((n) => n + media.length);
      for (const file of media) {
        try {
          await createProjectFromFile(file, folderId);
        } catch {
          // A file the engine can't ingest is skipped; the rest still land.
        } finally {
          setImporting((n) => n - 1);
        }
        await refresh();
      }
    },
    [refresh]
  );

  const rename = async () => {
    if (!renaming) return;
    setBusy(true);
    try {
      await apiFetch(`/api/cut/projects/${renaming.id}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim() || renaming.name }),
      });
      setRenaming(null);
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  const duplicate = async (p: ProjectSummary) => {
    setBusy(true);
    try {
      await apiFetch(`/api/cut/projects/${p.id}/duplicate`, { method: "POST" });
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!deleting) return;
    setBusy(true);
    try {
      await apiFetch(`/api/cut/projects/${deleting.id}`, { method: "DELETE" });
      setDeleting(null);
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  const all = projects ?? [];
  const shown = all.filter((p) => (p.folderId ?? null) === openFolder);
  const openFolderName = folders.find((f) => f.id === openFolder)?.name;
  const hasContent = all.length > 0 || folders.length > 0;

  // Begin a project drag. Dragging a member of the current selection carries the
  // whole selection; dragging anything else drags (and selects) just that item.
  const onProjectDragStart = (e: React.DragEvent, p: ProjectSummary) => {
    const ids = selected.has(p.id) && selected.size > 0 ? Array.from(selected) : [p.id];
    if (!selected.has(p.id)) setSelected(new Set([p.id]));
    e.dataTransfer.setData(PROJECT_MIME, JSON.stringify(ids));
    e.dataTransfer.effectAllowed = "move";
    const ghost = buildDragGhost(ids.length, ids.length > 1 ? `${ids.length} projects` : p.name);
    document.body.appendChild(ghost);
    e.dataTransfer.setDragImage(ghost, 18, 16);
    setTimeout(() => ghost.remove(), 0);
  };

  const toggleSelect = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  // Only OS-file drags are drop targets here; internal project drags carry
  // PROJECT_MIME and are handled by the folder tiles and breadcrumb instead.
  const isFileDrag = (e: React.DragEvent) => Array.from(e.dataTransfer.types).includes("Files");

  return (
    <div
      className={cn(
        "relative mx-auto w-full max-w-6xl px-10 py-9",
        fileOver &&
          "rounded-3xl outline-2 outline-dashed outline-offset-[-10px] outline-[#0a84ff]/60"
      )}
      onDragEnter={(e) => {
        if (engineDown || !isFileDrag(e)) return;
        e.preventDefault();
        dragDepth.current += 1;
        setFileOver(true);
      }}
      onDragOver={(e) => {
        if (engineDown || !isFileDrag(e)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      }}
      onDragLeave={(e) => {
        if (!isFileDrag(e)) return;
        dragDepth.current -= 1;
        if (dragDepth.current <= 0) {
          dragDepth.current = 0;
          setFileOver(false);
        }
      }}
      onDrop={(e) => {
        if (engineDown || !isFileDrag(e)) return;
        e.preventDefault();
        dragDepth.current = 0;
        setFileOver(false);
        void importFilesAsProjects(e.dataTransfer.files, openFolder);
      }}
    >
      {importing > 0 && (
        <div className="pointer-events-none fixed right-6 bottom-6 z-50 grid size-11 place-items-center rounded-full bg-foreground/90 text-background shadow-lg">
          <Loader2 className="size-5 animate-spin" />
        </div>
      )}
      {!engineDown && projects && hasContent && (
        <div className="mb-5 flex items-center justify-between">
          {openFolder === null ? (
            <h1 className="text-lg font-semibold tracking-tight">Projects</h1>
          ) : (
            <FolderCrumb
              root="Projects"
              name={openFolderName ?? "Folder"}
              mime={PROJECT_MIME}
              onBack={() => {
                setSelected(new Set());
                setOpenFolder(null);
              }}
              onDropOut={(ids) => void moveProjects(ids, null)}
            />
          )}
          {projects.length > 0 && (
            <div className="flex rounded-lg border border-border bg-card p-0.5">
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Gallery view"
                aria-pressed={view === "gallery"}
                className={cn(view === "gallery" && "bg-muted text-foreground")}
                onClick={() => switchView("gallery")}
              >
                <LayoutGrid />
              </Button>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="List view"
                aria-pressed={view === "list"}
                className={cn(view === "list" && "bg-muted text-foreground")}
                onClick={() => switchView("list")}
              >
                <List />
              </Button>
            </div>
          )}
        </div>
      )}

      {!engineDown && projects && openFolder === null && hasContent && (
        <FolderShelf
          folders={folders}
          mime={PROJECT_MIME}
          statOf={(id) => {
            const items = all.filter((p) => (p.folderId ?? null) === id);
            return { count: items.length, size: items.reduce((n, p) => n + (p.sizeBytes ?? 0), 0) };
          }}
          onOpen={(id) => {
            setSelected(new Set());
            setOpenFolder(id);
          }}
          onCreate={createFolder}
          onRename={renameFolder}
          onDelete={deleteFolder}
          onDropIds={(ids, fid) => void moveProjects(ids, fid)}
          onDropFiles={(files, fid) => void importFilesAsProjects(files, fid)}
        />
      )}

      {engineDown ? (
        <div className="grid min-h-[60vh] place-items-center">
          <div className="flex max-w-sm flex-col items-center gap-4 text-center">
            <div className="grid size-14 place-items-center rounded-2xl bg-muted">
              <Unplug className="size-7 text-muted-foreground" />
            </div>
            <h1 className="text-lg font-semibold tracking-tight">
              Donkey Cut works with the Donkey app
            </h1>
            <p className="text-sm text-muted-foreground">
              Everything runs locally on your Mac. Install Donkey — or open it
              if it&rsquo;s already installed — and this page connects
              automatically.
            </p>
            <div className="flex items-center gap-2">
              <Button onClick={() => window.open("https://donkeyuse.com", "_blank")}>
                Get Donkey for Mac
              </Button>
              <Button
                variant="ghost"
                onClick={() => {
                  setEngineDown(false);
                  setProjects(null);
                  void refresh();
                }}
              >
                Try again
              </Button>
            </div>
          </div>
        </div>
      ) : projects === null ? (
        <div className="grid place-items-center py-24 text-muted-foreground">
          <Loader2 className="size-5 animate-spin" />
        </div>
      ) : !hasContent ? (
        <div className="grid min-h-[60vh] place-items-center">
          <div className="flex flex-col items-center gap-4 text-center">
            <div className="grid size-14 place-items-center rounded-2xl bg-muted">
              <Film className="size-7 text-muted-foreground" />
            </div>
            <h1 className="text-lg font-semibold tracking-tight">
              Create a new project to get started
            </h1>
            <Button
              onClick={() => {
                setName("");
                setCreateOpen(true);
              }}
            >
              <Plus data-icon="inline-start" /> New project
            </Button>
          </div>
        </div>
      ) : view === "gallery" ? (
        <Marquee
          className="grid min-h-[42vh] grid-cols-[repeat(auto-fill,minmax(190px,1fr))] content-start gap-5"
          selected={selected}
          setSelected={setSelected}
        >
          {shown.map((p) => (
            <div
              key={p.id}
              data-sel-id={p.id}
              className="group cursor-pointer"
              draggable
              onDragStart={(e) => onProjectDragStart(e, p)}
              onClick={(e) => {
                if (e.shiftKey || e.metaKey) {
                  e.preventDefault();
                  toggleSelect(p.id);
                  return;
                }
                router.push(projectHref(base, p.id, "projects"));
              }}
            >
              {/* Vertical 9:16 tile — the project is mobile video, show it that way. */}
              <div
                className={cn(
                  "relative grid aspect-[9/16] place-items-center overflow-hidden rounded-2xl border bg-muted transition-shadow group-hover:shadow-[0_6px_28px_rgba(0,0,0,0.12)]",
                  selected.has(p.id) ? "border-[#0a84ff] ring-2 ring-[#0a84ff]" : "border-border"
                )}
              >
                <CardPreview project={p} />
                <span className="absolute top-2 left-2 max-w-[70%] truncate rounded-lg bg-black/55 px-2 py-1 text-[11px] font-medium text-white backdrop-blur-sm">
                  {p.name}
                </span>
                <span className="absolute right-2 bottom-2 rounded-md bg-black/65 px-1.5 py-0.5 font-mono text-[10px] text-white tabular-nums">
                  {formatTime(p.duration)}
                </span>
                <ProjectMenu
                  project={p}
                  className="absolute top-1.5 right-1.5 opacity-0 group-hover:opacity-100 data-[state=open]:opacity-100"
                  folders={folders}
                  onRename={() => {
                    setName(p.name);
                    setRenaming(p);
                  }}
                  onDuplicate={() => void duplicate(p)}
                  onMove={(folderId) => void moveProjects([p.id], folderId)}
                  onDelete={() => setDeleting(p)}
                />
              </div>
              <div className="mt-2 px-0.5 text-xs text-muted-foreground">
                {p.clipCount} {p.clipCount === 1 ? "clip" : "clips"} · edited{" "}
                {formatDate(p.updatedAt)}
              </div>
            </div>
          ))}
          <button
            type="button"
            data-no-marquee
            aria-label="New project"
            onClick={() => void newProjectHere()}
            className="group/new flex flex-col"
          >
            <span className="grid aspect-[9/16] place-items-center rounded-2xl border-2 border-dashed border-border text-muted-foreground transition-colors group-hover/new:border-[#0a84ff] group-hover/new:bg-[#0a84ff]/5 group-hover/new:text-[#0a84ff]">
              <Plus className="size-8" />
            </span>
          </button>
        </Marquee>
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card">
          <div className="grid grid-cols-[1fr_90px_70px_110px_40px] items-center gap-3 border-b border-border bg-muted/50 px-4 py-2 text-xs font-medium tracking-wide text-muted-foreground uppercase">
            <span>Name</span>
            <span>Length</span>
            <span>Clips</span>
            <span>Edited</span>
            <span />
          </div>
          {shown.map((p) => (
            <div
              key={p.id}
              data-sel-id={p.id}
              className={cn(
                "group grid cursor-pointer grid-cols-[1fr_90px_70px_110px_40px] items-center gap-3 border-b border-border px-4 py-2.5 text-sm last:border-b-0 hover:bg-muted/50",
                selected.has(p.id) && "bg-[#0a84ff]/10 hover:bg-[#0a84ff]/15"
              )}
              draggable
              onDragStart={(e) => onProjectDragStart(e, p)}
              onClick={(e) => {
                if (e.shiftKey || e.metaKey) {
                  e.preventDefault();
                  toggleSelect(p.id);
                  return;
                }
                router.push(projectHref(base, p.id, "projects"));
              }}
            >
              <span className="flex min-w-0 items-center gap-2.5">
                <Film className="size-4 shrink-0 text-muted-foreground" />
                <span className="truncate font-medium">{p.name}</span>
              </span>
              <span className="font-mono text-xs text-muted-foreground tabular-nums">
                {formatTime(p.duration)}
              </span>
              <span className="text-xs text-muted-foreground">{p.clipCount}</span>
              <span className="text-xs text-muted-foreground">
                {formatDate(p.updatedAt)}
              </span>
              <ProjectMenu
                project={p}
                folders={folders}
                onRename={() => {
                  setName(p.name);
                  setRenaming(p);
                }}
                onDuplicate={() => void duplicate(p)}
                onMove={(folderId) => void moveProjects([p.id], folderId)}
                onDelete={() => setDeleting(p)}
              />
            </div>
          ))}
          <button
            type="button"
            data-no-marquee
            onClick={() => void newProjectHere()}
            className="flex w-full items-center gap-2.5 px-4 py-2.5 text-sm font-medium text-muted-foreground transition-colors hover:bg-muted/50 hover:text-foreground"
          >
            <Plus className="size-4" /> New project
          </button>
        </div>
      )}

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>New project</DialogTitle>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void create();
            }}
          >
            <Input
              autoFocus
              placeholder="Project name"
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
            <DialogFooter className="mt-4">
              <Button type="submit" disabled={busy} className="w-full">
                {busy && <Loader2 className="animate-spin" data-icon="inline-start" />}
                Create project
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog open={!!renaming} onOpenChange={(o) => !o && setRenaming(null)}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Rename project</DialogTitle>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void rename();
            }}
          >
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
            <DialogFooter className="mt-4">
              <Button type="submit" disabled={busy} className="w-full">
                Rename
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <AlertDialog open={!!deleting} onOpenChange={(o) => !o && setDeleting(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete “{deleting?.name}”?</AlertDialogTitle>
            <AlertDialogDescription>
              This deletes the whole project folder, including its media files
              and exports. This can’t be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              disabled={busy}
              className="bg-destructive/10 text-destructive hover:bg-destructive/20"
              onClick={(e) => {
                e.preventDefault();
                void remove();
              }}
            >
              Delete project
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/** Card art: the actual edit (a rendered proxy) plays on hover; the poster is
 * the first clip's real first frame. Falls back to the source when no proxy
 * has been rendered yet. */
function CardPreview({ project: p }: { project: ProjectSummary }) {
  const videoRef = useRef<HTMLVideoElement>(null);

  if (!p.previewFile && !p.hasPreview) {
    return (
      <Film className="size-7 text-muted-foreground/50 transition-transform group-hover:scale-110" />
    );
  }

  // The proxy starts at the edit's first frame; the source starts at the clip's
  // trim-in, so both posters show what actually plays first.
  const posterT = p.hasPreview ? 0 : p.previewStart ?? 0.1;
  const src = p.hasPreview
    ? apiUrl(`/api/cut/projects/${p.id}/preview`)
    : mediaUrl(p.id, p.previewFile!);

  return (
    <div
      className="absolute inset-0"
      onMouseEnter={() => void videoRef.current?.play().catch(() => {})}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = posterT;
        }
      }}
    >
      <video
        ref={videoRef}
        src={`${src}#t=${posterT}`}
        muted
        loop
        playsInline
        preload="metadata"
        className="size-full object-cover"
      />
    </div>
  );
}

function ProjectMenu({
  project: p,
  className,
  folders,
  onRename,
  onDuplicate,
  onMove,
  onDelete,
}: {
  project: ProjectSummary;
  className?: string;
  folders: ProjectFolder[];
  onRename: () => void;
  onDuplicate: () => void;
  onMove: (folderId: string | null) => void;
  onDelete: () => void;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Project actions"
            className={cn("bg-black/40 text-white hover:bg-black/60 hover:text-white", className)}
            onClick={(e) => e.stopPropagation()}
          />
        }
      >
        <MoreHorizontal />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" onClick={(e) => e.stopPropagation()}>
        <DropdownMenuItem onClick={onRename}>
          <Pencil /> Rename
        </DropdownMenuItem>
        <DropdownMenuItem onClick={onDuplicate}>
          <Copy /> Duplicate
        </DropdownMenuItem>
        {folders.length > 0 && (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => onMove(null)}>
              {(p.folderId ?? null) === null && <Check />} No folder
            </DropdownMenuItem>
            {folders.map((f) => (
              <DropdownMenuItem key={f.id} onClick={() => onMove(f.id)}>
                {p.folderId === f.id ? <Check /> : <Folder />} {f.name}
              </DropdownMenuItem>
            ))}
          </>
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" onClick={onDelete}>
          <Trash2 /> Delete
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

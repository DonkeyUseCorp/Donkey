"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  Film,
  LayoutGrid,
  List,
  Loader2,
  MoreHorizontal,
  Pencil,
  Trash2,
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
import { formatTime } from "@/cut/lib/time";
import { mediaUrl, type ProjectSummary } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

type View = "gallery" | "list";

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
  const [projects, setProjects] = useState<ProjectSummary[] | null>(null);
  const [view, setView] = useState<View>("gallery");
  const [createOpen, setCreateOpen] = useState(false);
  const [renaming, setRenaming] = useState<ProjectSummary | null>(null);
  const [deleting, setDeleting] = useState<ProjectSummary | null>(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem("cut-projects-view");
    if (saved === "list" || saved === "gallery") setView(saved);
  }, []);

  const switchView = (v: View) => {
    setView(v);
    localStorage.setItem("cut-projects-view", v);
  };

  const refresh = useCallback(async () => {
    const res = await fetch("/api/projects");
    setProjects((await res.json()) as ProjectSummary[]);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const create = async () => {
    setBusy(true);
    try {
      const res = await fetch("/api/projects", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim() || "Untitled" }),
      });
      const project = (await res.json()) as ProjectSummary;
      router.push(`/p/${project.id}`);
    } finally {
      setBusy(false);
    }
  };

  const rename = async () => {
    if (!renaming) return;
    setBusy(true);
    try {
      await fetch(`/api/projects/${renaming.id}`, {
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

  const remove = async () => {
    if (!deleting) return;
    setBusy(true);
    try {
      await fetch(`/api/projects/${deleting.id}`, { method: "DELETE" });
      setDeleting(null);
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto w-full max-w-6xl px-10 py-9">
      <div className="mb-5 flex items-center justify-between">
        <h1 className="text-lg font-semibold tracking-tight">Recent videos</h1>
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
      </div>

      {projects === null ? (
        <div className="grid place-items-center py-24 text-muted-foreground">
          <Loader2 className="size-5 animate-spin" />
        </div>
      ) : projects.length === 0 ? (
        <button
          className="grid w-full cursor-pointer place-items-center rounded-2xl border-2 border-dashed border-border py-24 transition-colors hover:border-primary/40"
          onClick={() => {
            setName("");
            setCreateOpen(true);
          }}
        >
          <div className="flex flex-col items-center gap-3 text-center">
            <Film className="size-8 text-muted-foreground" />
            <div className="text-base font-medium">No videos yet</div>
            <p className="max-w-xs text-sm text-muted-foreground">
              Create your first project, then drop in videos and music to start
              cutting.
            </p>
          </div>
        </button>
      ) : view === "gallery" ? (
        <div className="grid grid-cols-[repeat(auto-fill,minmax(190px,1fr))] gap-5">
          {projects.map((p) => (
            <div
              key={p.id}
              className="group cursor-pointer"
              onClick={() => router.push(`/p/${p.id}`)}
            >
              {/* Vertical 9:16 tile — the project is mobile video, show it that way. */}
              <div className="relative grid aspect-[9/16] place-items-center overflow-hidden rounded-2xl border border-border bg-muted transition-shadow group-hover:shadow-[0_6px_28px_rgba(0,0,0,0.12)]">
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
                  onRename={() => {
                    setName(p.name);
                    setRenaming(p);
                  }}
                  onDelete={() => setDeleting(p)}
                />
              </div>
              <div className="mt-2 px-0.5 text-xs text-muted-foreground">
                {p.clipCount} {p.clipCount === 1 ? "clip" : "clips"} · edited{" "}
                {formatDate(p.updatedAt)}
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card">
          <div className="grid grid-cols-[1fr_90px_70px_110px_40px] items-center gap-3 border-b border-border bg-muted/50 px-4 py-2 text-xs font-medium tracking-wide text-muted-foreground uppercase">
            <span>Name</span>
            <span>Length</span>
            <span>Clips</span>
            <span>Edited</span>
            <span />
          </div>
          {projects.map((p) => (
            <div
              key={p.id}
              className="group grid cursor-pointer grid-cols-[1fr_90px_70px_110px_40px] items-center gap-3 border-b border-border px-4 py-2.5 text-sm last:border-b-0 hover:bg-muted/50"
              onClick={() => router.push(`/p/${p.id}`)}
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
                onRename={() => {
                  setName(p.name);
                  setRenaming(p);
                }}
                onDelete={() => setDeleting(p)}
              />
            </div>
          ))}
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

/** Card art: a real frame from the project's first video, playing on hover. */
function CardPreview({ project: p }: { project: ProjectSummary }) {
  const videoRef = useRef<HTMLVideoElement>(null);

  if (!p.previewFile) {
    return (
      <Film className="size-7 text-muted-foreground/50 transition-transform group-hover:scale-110" />
    );
  }

  return (
    <div
      className="absolute inset-0"
      onMouseEnter={() => void videoRef.current?.play().catch(() => {})}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = 0.1;
        }
      }}
    >
      <video
        ref={videoRef}
        src={`${mediaUrl(p.id, p.previewFile)}#t=0.1`}
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
  project: _p,
  className,
  onRename,
  onDelete,
}: {
  project: ProjectSummary;
  className?: string;
  onRename: () => void;
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
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" onClick={onDelete}>
          <Trash2 /> Delete
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Clapperboard, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { apiFetch } from "@/cut/lib/api";
import { enrichAsset, importFileToProject } from "@/cut/lib/media";
import { serializeDoc, totalDuration, useEditor } from "@/cut/lib/store";
import { AiPanel } from "./AiPanel";
import { ExportDialog } from "./ExportDialog";
import { Inspector } from "./Inspector";
import { Preview } from "./Preview";
import { SidePanel } from "./SidePanel";
import { Timeline } from "./Timeline";
import { TopBar } from "./TopBar";

export function Editor({ projectId }: { projectId: string }) {
  const loaded = useEditor((s) => s.loaded);
  const loadError = useEditor((s) => s.loadError);
  const dropActive = useEditor((s) => s.dropActive);
  const exportOpen = useEditor((s) => s.exportOpen);
  const aiOpen = useEditor((s) => s.aiOpen);
  const [importing, setImporting] = useState(0);
  const dragDepth = useRef(0);

  // Load the project document, then enrich assets (thumbs/waveforms) lazily.
  useEffect(() => {
    void useEditor
      .getState()
      .loadProject(projectId)
      .then(() => {
        for (const asset of useEditor.getState().assets) void enrichAsset(asset);
      });
  }, [projectId]);

  // Autosave: debounce document changes into PUT /api/projects/<id>.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    let last = serializeDoc(useEditor.getState());
    let lastName = useEditor.getState().projectName;

    const save = async () => {
      const s = useEditor.getState();
      if (!s.loaded || s.projectId !== projectId) return;
      s.setSaveState("saving");
      try {
        const res = await apiFetch(`/api/projects/${projectId}`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(serializeDoc(s)),
        });
        if (!res.ok) throw new Error();
        useEditor.getState().setSaveState("saved");
      } catch {
        useEditor.getState().setSaveState("error");
      }
    };

    let primed = false;
    const unsub = useEditor.subscribe((s) => {
      if (!s.loaded || s.projectId !== projectId) return;
      if (!primed) {
        // First tick after load: snapshot the freshly loaded doc so opening
        // a project never counts as an edit.
        primed = true;
        last = serializeDoc(s);
        lastName = s.projectName;
        return;
      }
      const changed =
        s.clips !== (last.clips as unknown) ||
        s.audioClips !== (last.audioClips as unknown) ||
        s.overlays !== (last.overlays as unknown) ||
        s.subtitles !== (last.subtitles as unknown) ||
        s.aspect !== last.aspect ||
        s.assets.length !== last.assets?.length ||
        s.publish.caption !== last.publish?.caption ||
        s.publish.tags !== last.publish?.tags ||
        s.publish.soundTitle !== last.publish?.soundTitle ||
        s.publish.handle !== last.publish?.handle ||
        s.projectName !== lastName;
      if (!changed) return;
      last = serializeDoc(s);
      lastName = s.projectName;
      if (s.saveState !== "saving") s.setSaveState("dirty");
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => void save(), 800);
    });
    return () => {
      unsub();
      if (timer) clearTimeout(timer);
    };
  }, [projectId]);

  const importFiles = useCallback(
    async (files: FileList | File[]) => {
      const list = Array.from(files);
      setImporting((n) => n + list.length);
      for (const file of list) {
        try {
          const asset = await importFileToProject(projectId, file);
          if (!asset) continue;
          const s = useEditor.getState();
          s.addAsset(asset);
          if (asset.type === "video") s.addClipFromAsset(asset.id);
          else s.addAudioFromAsset(asset.id, 0);
          void enrichAsset(asset);
        } catch (err) {
          console.error(`Import failed for ${file.name}:`, err);
        } finally {
          setImporting((n) => n - 1);
        }
      }
    },
    [projectId]
  );

  // Whole-window drag & drop.
  useEffect(() => {
    const enter = (e: DragEvent) => {
      if (!e.dataTransfer?.types.includes("Files")) return;
      e.preventDefault();
      dragDepth.current++;
      useEditor.getState().setDropActive(true);
    };
    const over = (e: DragEvent) => {
      if (e.dataTransfer?.types.includes("Files")) e.preventDefault();
    };
    const leave = (e: DragEvent) => {
      if (!e.dataTransfer?.types.includes("Files")) return;
      dragDepth.current = Math.max(0, dragDepth.current - 1);
      if (dragDepth.current === 0) useEditor.getState().setDropActive(false);
    };
    const drop = (e: DragEvent) => {
      if (!e.dataTransfer?.files.length) return;
      e.preventDefault();
      dragDepth.current = 0;
      useEditor.getState().setDropActive(false);
      void importFiles(e.dataTransfer.files);
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  }, [importFiles]);

  // Keyboard shortcuts.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      const inputType = (target as HTMLInputElement).type;
      const textEntry =
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT" ||
        target.isContentEditable ||
        (target.tagName === "INPUT" &&
          !["checkbox", "radio", "range", "button"].includes(inputType));
      if (textEntry) return;
      // Let native toggle/slider behavior win for focused controls.
      const controlFocused =
        target.tagName === "INPUT" || target.closest('[role="switch"],[role="slider"]') !== null;
      const s = useEditor.getState();
      if (s.exportOpen || document.querySelector('[data-slot="dialog-content"]')) return;

      if (e.code === "Space" && !controlFocused) {
        e.preventDefault();
        if (!s.playing && s.currentTime >= totalDuration(s.clips) - 0.01) s.seek(0);
        s.setPlaying(!s.playing);
      } else if (e.key === "Backspace" || e.key === "Delete") {
        e.preventDefault();
        s.deleteSelection();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) s.redo();
        else s.undo();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "c") {
        if (s.copySelection()) e.preventDefault();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "v") {
        if (s.paste()) e.preventDefault();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "j") {
        e.preventDefault();
        s.setAiOpen(!s.aiOpen);
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "b") {
        e.preventDefault();
        // iMovie: cut at the skimmer when the mouse is over the timeline.
        s.splitAtPlayhead(s.skimTime ?? undefined);
      } else if (e.key.toLowerCase() === "s" && !e.metaKey && !e.ctrlKey) {
        s.splitAtPlayhead(s.skimTime ?? undefined);
      } else if (e.key.toLowerCase() === "t" && !e.metaKey && !e.ctrlKey) {
        s.addOverlay();
      } else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && !controlFocused) {
        e.preventDefault();
        const step = e.shiftKey ? 1 : 1 / 30;
        s.seek(s.currentTime + (e.key === "ArrowLeft" ? -step : step));
      } else if (e.key === "Escape") {
        s.select(null);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (loadError) {
    return (
      <div className="grid h-screen place-items-center">
        <div className="flex flex-col items-center gap-3 text-center">
          <Clapperboard className="size-7 text-muted-foreground" />
          <p className="text-sm text-muted-foreground">{loadError}</p>
          <Button
            variant="outline"
            nativeButton={false}
            render={<Link href="/">Back to projects</Link>}
          />
        </div>
      </div>
    );
  }

  if (!loaded) {
    return (
      <div className="grid h-screen place-items-center text-muted-foreground">
        <Loader2 className="size-5 animate-spin" />
      </div>
    );
  }

  return (
    <div className="flex h-screen min-w-[900px] select-none overflow-hidden">
      <div className="grid min-w-0 flex-1 grid-rows-[46px_minmax(0,1fr)_auto]">
        <TopBar />
        <div className="grid min-h-0 grid-cols-[auto_minmax(0,1fr)_272px]">
          <SidePanel projectId={projectId} onImport={importFiles} importing={importing > 0} />
          <Preview />
          <Inspector />
        </div>
        <Timeline />
      </div>
      {aiOpen && <AiPanel onClose={() => useEditor.getState().setAiOpen(false)} />}
      {exportOpen && <ExportDialog />}
      {dropActive && (
        <div className="fixed inset-0 z-60 grid place-items-center bg-background/70 backdrop-blur-md">
          <div className="pointer-events-none flex flex-col items-center gap-2 rounded-2xl border-2 border-dashed border-[#0a84ff] bg-[#0a84ff]/10 px-12 py-9 text-[#0a84ff]">
            <Clapperboard className="size-7" />
            <div className="text-[15px] font-semibold text-foreground">
              Drop to add to your project
            </div>
            <div className="text-xs text-muted-foreground">
              Videos land on the timeline · music on the soundtrack
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

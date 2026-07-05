"use client";

import { useState } from "react";
import Link from "next/link";
import { Check, ChevronDown, ChevronLeft, Loader2, Monitor, Smartphone, Sparkles, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useEditor } from "@/cut/lib/store";
import { ASPECT_LABEL, type Aspect } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

export function TopBar() {
  const hasClips = useEditor((s) => s.clips.length > 0);
  const aspect = useEditor((s) => s.aspect);
  const projectName = useEditor((s) => s.projectName);
  const saveState = useEditor((s) => s.saveState);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");

  const commitName = () => {
    setEditing(false);
    const name = draft.trim();
    if (name && name !== projectName) useEditor.getState().setProjectName(name);
  };

  return (
    <header className="relative flex items-center justify-between border-b border-border bg-card pr-3 pl-2">
      <div className="absolute left-1/2 -translate-x-1/2">
        <DropdownMenu>
          <DropdownMenuTrigger className="aspect-switch flex items-center gap-1.5 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium text-muted-foreground shadow-xs transition-colors hover:text-foreground">
            {aspect === "9:16" ? <Smartphone className="size-3.5" /> : <Monitor className="size-3.5" />}
            {ASPECT_LABEL[aspect]}
            <ChevronDown className="size-3" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-56">
            {(Object.keys(ASPECT_LABEL) as Aspect[]).map((a) => (
              <DropdownMenuItem key={a} onClick={() => useEditor.getState().setAspect(a)}>
                {a === "9:16" ? <Smartphone /> : <Monitor />}
                <span className="flex-1">
                  {ASPECT_LABEL[a]}
                  <span className="block text-[10.5px] text-muted-foreground">
                    {a === "9:16" ? "TikTok, Reels, Shorts" : "YouTube"}
                  </span>
                </span>
                {aspect === a && <Check className="size-3.5 text-coral" />}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <div className="flex min-w-0 items-center gap-1">
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label="Back to projects"
          nativeButton={false}
          render={<Link href="/" />}
        >
          <ChevronLeft />
        </Button>
        <span className="grid size-[22px] shrink-0 place-items-center overflow-hidden rounded-md">
          <img src="/donkey-logo.svg" alt="Donkey" className="block h-full w-full object-contain" />
        </span>
        {editing ? (
          <input
            autoFocus
            className="ml-1.5 h-7 w-52 rounded-md border border-input bg-transparent px-2 text-sm font-medium outline-none select-text focus:border-ring"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commitName}
            onKeyDown={(e) => {
              if (e.key === "Enter") commitName();
              if (e.key === "Escape") setEditing(false);
            }}
          />
        ) : (
          <button
            className="ml-1.5 max-w-64 cursor-text truncate rounded-md px-2 py-1 text-sm font-medium tracking-tight hover:bg-muted"
            title="Rename project"
            onClick={() => {
              setDraft(projectName);
              setEditing(true);
            }}
          >
            {projectName}
          </button>
        )}
        <span
          className={cn(
            "ml-2 flex items-center gap-1 text-[11px] text-muted-foreground transition-opacity",
            saveState === "saved" && "opacity-60"
          )}
        >
          {saveState === "saving" || saveState === "dirty" ? (
            <>
              <Loader2 className="size-3 animate-spin" /> Saving
            </>
          ) : saveState === "error" ? (
            <span className="text-destructive">Couldn’t save</span>
          ) : (
            <>
              <Check className="size-3" /> Saved
            </>
          )}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <Button
          variant="ghost"
          size="sm"
          className="ai-toggle"
          aria-label="Chat"
          title="Chat (⌘J)"
          onClick={() => {
            const s = useEditor.getState();
            s.setAiOpen(!s.aiOpen);
          }}
        >
          <Sparkles data-icon="inline-start" /> Chat
        </Button>
        <Button
          size="sm"
          disabled={!hasClips}
          onClick={() => {
            const s = useEditor.getState();
            s.setPlaying(false);
            s.setExportOpen(true);
          }}
        >
          <Upload data-icon="inline-start" /> Export
        </Button>
      </div>
    </header>
  );
}

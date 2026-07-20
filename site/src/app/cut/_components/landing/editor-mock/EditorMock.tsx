"use client";

import { useEffect, useRef, useState } from "react";

import "./editor-mock.css";

import { MockAiPanel } from "@/app/cut/_components/landing/editor-mock/MockAiPanel";
import { MockPreview } from "@/app/cut/_components/landing/editor-mock/MockPreview";
import { MockSidePanel } from "@/app/cut/_components/landing/editor-mock/MockSidePanel";
import { MockTimeline } from "@/app/cut/_components/landing/editor-mock/MockTimeline";
import { MockTopBar } from "@/app/cut/_components/landing/editor-mock/MockTopBar";
import { MOCK_PROJECTS } from "@/app/cut/_components/landing/editor-mock/mockData";
import { cn } from "@/lib/utils";

// The mock is authored at a fixed design size and scaled to the hero's width,
// so its internals never reflow — it behaves like a live screenshot.
const DESIGN_W = 1200;
const DESIGN_H = 726;

// A hand-built, display-only replica of the Cut editor showing two finished
// projects. The panels copy the real components' chrome (see the Mock*
// siblings) over hardcoded data — no stores, no engine. The dots below switch
// projects; nothing auto-advances.
export function EditorMock() {
  const [active, setActive] = useState(0);
  const frameRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);

  useEffect(() => {
    const el = frameRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => {
      setScale(entry.contentRect.width / DESIGN_W);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return (
    <figure className="m-0">
      <div ref={frameRef} className="w-full">
        <div style={{ height: Math.round(DESIGN_H * scale) }}>
          <div
            aria-hidden
            className="pointer-events-none relative origin-top-left overflow-hidden rounded-2xl bg-card font-system text-foreground antialiased shadow-[0_0_0_1px_rgba(0,0,0,0.08),0_24px_64px_rgba(15,14,13,0.25)] select-none"
            style={{ width: DESIGN_W, height: DESIGN_H, transform: `scale(${scale})` }}
          >
            {MOCK_PROJECTS.map((project, i) => (
              <div
                key={project.id}
                className={cn(
                  // Same frame as the real editor: the chat panel is a
                  // full-height column beside the top-bar/preview/timeline grid.
                  "absolute inset-0 flex bg-card transition-opacity duration-300",
                  i === active ? "opacity-100" : "opacity-0",
                )}
              >
                <div className="grid min-w-0 flex-1 grid-rows-[46px_minmax(0,1fr)_auto]">
                  <MockTopBar project={project} />
                  <div className="grid min-h-0 grid-cols-[auto_minmax(0,1fr)]">
                    <MockSidePanel project={project} />
                    <MockPreview project={project} active={i === active} />
                  </div>
                  <MockTimeline project={project} />
                </div>
                <MockAiPanel project={project} />
              </div>
            ))}
          </div>
        </div>
      </div>
      <figcaption className="sr-only">
        The Donkey Cut editor with a finished project open: generated media in
        the side panel, clips and music on the timeline, and the AI chat that
        assembled them.
      </figcaption>
      <div className="mt-6 flex flex-wrap justify-center gap-1.5">
        {MOCK_PROJECTS.map((project, i) => (
          <button
            key={project.id}
            type="button"
            onClick={() => setActive(i)}
            aria-pressed={i === active}
            className={cn(
              "flex items-center gap-1.5 rounded-full border border-ink px-2.5 py-0.5 text-xs font-medium transition-colors",
              i === active ? "bg-ink text-white" : "bg-white text-ink hover:bg-ink/5",
            )}
          >
            <span
              className={cn(
                "size-1.5 rounded-full",
                i === active ? "bg-coral" : "bg-ink/25",
              )}
            />
            {project.switcherLabel}
          </button>
        ))}
      </div>
    </figure>
  );
}

import {
  Boxes,
  Crosshair,
  ImageIcon,
  ListChecks,
  MousePointerClick,
  SlidersHorizontal,
  Sparkles,
  Type,
  Video,
  Zap,
} from "lucide-react";

import type { Feature, Stat } from "@/app/donkeyvision/types";

export const stats: Stat[] = [
  {
    eyebrow: "Server-side",
    label:
      "Process a screenshot into structured UI elements — boxes, labels, OCR, and click coordinates — in under a second.",
    value: "~0.7s",
  },
];

export const features: Feature[] = [
  {
    description:
      "Buttons, icons, inputs, links, rows, text targets, and other visible UI regions.",
    icon: Boxes,
    title: "Detected elements",
  },
  {
    description:
      "Bounding boxes and center points are returned in the original screenshot coordinate space.",
    icon: Crosshair,
    title: "Coordinates",
  },
  {
    description:
      "Each element includes a readable label and kind, such as `button`, `input`, `icon`, or `text`.",
    icon: Type,
    title: "Labels and types",
  },
  {
    description:
      "Natural language instructions return the matching element, click point, and region.",
    icon: MousePointerClick,
    title: "Prompt-to-click",
  },
  {
    description:
      "Per-request thresholds control detection sensitivity and element merging.",
    icon: SlidersHorizontal,
    title: "Detection options",
  },
  {
    description:
      "Prompt-based targeting supports ChatGPT, Claude, Gemini, or a custom model.",
    icon: Sparkles,
    title: "Model choice",
  },
];

export const useCases: Feature[] = [
  {
    description:
      "Give agents the current screen state before taking action. Return clickable elements, coordinates, labels, and prompt-matched targets for tasks like `click the play button`.",
    icon: Zap,
    title: "Computer-use agents",
  },
  {
    description:
      "Convert screenshots into structured UI data: detected elements, text labels, element types, bounding boxes, and center points.",
    icon: ImageIcon,
    title: "Screenshot parsing",
  },
  {
    description:
      "Parse video frames into UI element timelines. Track visible controls, labels, and screen changes across demos, workflows, and regression tests.",
    icon: Video,
    title: "Video frame analysis",
  },
  {
    description:
      "Find click targets across native apps, web apps, Electron apps, VNC sessions, and remote desktops without DOM access or app-specific selectors.",
    icon: ListChecks,
    title: "Cross-app automation",
  },
];

export const surfaces: string[] = [
  "Native macOS apps",
  "Web apps in any browser",
  "Electron and hybrid apps",
  "Remote desktops and VNC sessions",
  "Enterprise and internal tools",
  "Games and media players",
];

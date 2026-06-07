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
      "Each element includes a bounding box and center point in the same image coordinate space.",
    icon: Crosshair,
    title: "Coordinates",
  },
  {
    description:
      "Each element includes a readable label and kind, such as button, input, icon, or text.",
    icon: Type,
    title: "Labels and types",
  },
  {
    description:
      "Send a natural language instruction and get back the matching element, click point, and region.",
    icon: MousePointerClick,
    title: "Prompt-to-click",
  },
  {
    description:
      "Adjust thresholds per request to control sensitivity and element merging.",
    icon: SlidersHorizontal,
    title: "Detection options",
  },
  {
    description:
      "Use ChatGPT, Claude, Gemini, or bring your own custom model for prompt-based targeting.",
    icon: Sparkles,
    title: "Model choice",
  },
];

export const useCases: Feature[] = [
  {
    description:
      "Give an agent a fresh map of the current app before it decides where to click, type, or ask for confirmation.",
    icon: Zap,
    title: "Computer-use agents",
  },
  {
    description:
      "Index screenshots from common applications so QA, support, and automation systems can reason over UI state.",
    icon: ImageIcon,
    title: "Screenshot understanding",
  },
  {
    description:
      "Turn video frames into UI element timelines for product demos, workflow mining, and regression review.",
    icon: Video,
    title: "Video walkthroughs",
  },
  {
    description:
      "Find the next step in unfamiliar software without relying on DOM access, app-specific integrations, or brittle selectors.",
    icon: ListChecks,
    title: "Cross-app workflow routing",
  },
];

export const surfaces: string[] = [
  "Native macOS apps",
  "Web apps in any browser",
  "Electron and hybrid shells",
  "Remote desktop and VNC sessions",
  "Enterprise and internal tools",
  "Games and media players",
];

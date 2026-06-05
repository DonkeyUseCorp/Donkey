import {
  Boxes,
  Crosshair,
  ImageIcon,
  ListChecks,
  Monitor,
  SlidersHorizontal,
  Video,
  Zap,
} from "lucide-react";

import type { Feature, Stat } from "@/app/donkeyvision/types";

export const stats: Stat[] = [
  {
    eyebrow: "On the GPU",
    label:
      "Server-side time to detect, OCR, and label every element in a screenshot — the part we control.",
    value: "~0.2s",
  },
];

export const features: Feature[] = [
  {
    description:
      "Return every detected button, icon, input, row, link, and text target from a screenshot with boxes and center points.",
    icon: Boxes,
    title: "All interactable elements",
  },
  {
    description:
      "Each element comes back with a pixel-space bounding box and a center point, ready to click without any coordinate conversion.",
    icon: Crosshair,
    title: "Click-ready coordinates",
  },
  {
    description:
      "Works on native Mac apps, web apps, Electron shells, VNC sessions, enterprise tools, games, and remote desktops.",
    icon: Monitor,
    title: "Any software surface",
  },
  {
    description:
      "Tune box and IoU thresholds per request to control detection sensitivity and how aggressively overlapping elements are merged.",
    icon: SlidersHorizontal,
    title: "Tunable detection",
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

export const requestExample = `{
  "image": "<base64 png/jpeg/webp screenshot>",
  "options": {
    "boxThreshold": 0.05,
    "iouThreshold": 0.1
  }
}`;

export const elementResponseExample = `{
  "image": { "width": 1440, "height": 900 },
  "elements": [
    {
      "id": "a92kfq",
      "label": "Play",
      "kind": "button",
      "interactive": true,
      "box": { "x": 618, "y": 816, "width": 42, "height": 42 },
      "point": { "x": 639, "y": 837 },
      "confidence": 0.5
    }
  ]
}`;

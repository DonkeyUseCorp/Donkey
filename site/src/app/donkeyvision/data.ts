import {
  Boxes,
  Crosshair,
  ImageIcon,
  ListChecks,
  LockKeyhole,
  Monitor,
  Video,
  Zap,
} from "lucide-react";

import type { Feature, Stat } from "@/app/donkeyvision/types";

export const stats: Stat[] = [
  {
    eyebrow: "Full parse",
    label: "Typical time to detect and return every element in a screenshot.",
    value: "~600ms",
  },
  {
    eyebrow: "Parse + ground",
    label:
      "Typical time to detect, then ground a natural-language instruction to one target.",
    value: "~1.2s",
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
      "Ask for the play button, next button, search field, or any visible target. The LLM chooses from parsed element IDs.",
    icon: Crosshair,
    title: "Optional target grounding",
  },
  {
    description:
      "Works on native Mac apps, web apps, Electron shells, VNC sessions, enterprise tools, games, and remote desktops.",
    icon: Monitor,
    title: "Any software surface",
  },
  {
    description:
      "LLM inference receives detected IDs, labels, kinds, and interactivity flags. The screenshot and raw page content stay out of the grounding prompt.",
    icon: LockKeyhole,
    title: "Small LLM payloads",
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
  "returnElements": true,
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

export const groundingRequestExample = `{
  "image": "<base64 screenshot>",
  "instruction": "find the next button",
  "model": "gemini-2.5-flash",
  "returnElements": false
}`;

export const groundingResponseExample = `{
  "image": { "width": 1440, "height": 900 },
  "model": "gemini-2.5-flash",
  "target": {
    "elementId": "n8x2p0",
    "label": "Next",
    "kind": "button",
    "box": { "x": 1248, "y": 820, "width": 84, "height": 40 },
    "point": { "x": 1290, "y": 840 },
    "confidence": 0.86
  },
  "alternates": []
}`;

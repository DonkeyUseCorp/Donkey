import { z } from "zod";

import { toJsonObject } from "@/lib/inference/json";

const metadataSchema = z.record(z.string().min(1).max(64), z.string().max(512));
const coordinateSpaceSchema = z.enum(["screen", "window", "crop", "normalizedTarget"]);
const controlKindValues = [
  "button",
  "textField",
  "searchField",
  "checkbox",
  "link",
  "menuItem",
  "listItem",
  "group",
  "unknown",
] as const;
const controlKindSchema = z.enum(controlKindValues);
type ControlKind = z.infer<typeof controlKindSchema>;

export const hotLoopSizeSchema = z.object({
  width: z.number().positive().max(20_000),
  height: z.number().positive().max(20_000),
  space: coordinateSpaceSchema.default("window"),
});

export const hotLoopRectSchema = z.object({
  origin: z.object({
    x: z.number().finite(),
    y: z.number().finite(),
    space: coordinateSpaceSchema,
  }),
  size: hotLoopSizeSchema,
});

export const screenshotParseRequestSchema = z.object({
  imageBase64: z.string().min(1).max(6_000_000),
  contentType: z.enum(["image/png", "image/jpeg", "image/webp"]).default("image/png"),
  pixelSize: hotLoopSizeSchema,
  traceID: z.string().min(1).max(128).optional(),
  targetID: z.string().min(1).max(256).optional(),
  cropBounds: hotLoopRectSchema.optional(),
  metadata: metadataSchema.optional().default({}),
}).transform((value) => ({
  ...value,
  metadata: toJsonObject(value.metadata),
}));

export const geminiScreenshotTextSchema = z.object({
  id: clippedString(128).optional(),
  text: clippedString(2_000),
  confidence: z.number().min(0).max(1).optional().default(0.5),
});

export const geminiScreenshotControlSchema = z.object({
  id: clippedString(128).optional(),
  label: clippedString(256),
  kind: z.string().optional().default("unknown").transform(normalizedControlKind),
  confidence: z.number().min(0).max(1),
  box_2d: z.tuple([
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
  ]),
});

export const geminiScreenshotFormFieldSchema = z.object({
  id: clippedString(128).optional(),
  label: clippedString(256),
  isRequired: z.boolean().optional().default(false),
  currentValue: clippedString(1_000).nullable().optional(),
  confidence: z.number().min(0).max(1).optional().default(0.5),
  box_2d: z.tuple([
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
    z.number().min(0).max(1000),
  ]).optional(),
});

export const geminiScreenshotParseOutputSchema = z.object({
  visibleText: z.array(geminiScreenshotTextSchema).max(200).default([]),
  controls: z.array(geminiScreenshotControlSchema).max(200).default([]),
  formFields: z.array(geminiScreenshotFormFieldSchema).max(80).default([]),
  confidence: z.number().min(0).max(1).default(0),
});

export type ScreenshotParseRequest = z.infer<typeof screenshotParseRequestSchema>;
export type GeminiScreenshotParseOutput = z.infer<typeof geminiScreenshotParseOutputSchema>;
export type HotLoopRectJSON = z.infer<typeof hotLoopRectSchema>;

function clippedString(maxLength: number) {
  return z.string()
    .transform((value) => value.trim().slice(0, maxLength))
    .pipe(z.string().min(1));
}

function normalizedControlKind(value: string): ControlKind {
  const normalized = value.trim().toLowerCase().replace(/[^a-z]/g, "");
  switch (normalized) {
    case "button":
    case "iconbutton":
    case "toolbarbutton":
    case "reviewbutton":
    case "sendbutton":
      return "button";
    case "textfield":
    case "textinput":
    case "input":
    case "composer":
    case "textarea":
      return "textField";
    case "searchfield":
    case "search":
    case "searchinput":
      return "searchField";
    case "checkbox":
    case "toggle":
      return "checkbox";
    case "link":
      return "link";
    case "menuitem":
    case "menu":
    case "dropdown":
      return "menuItem";
    case "listitem":
    case "navitem":
    case "navigationitem":
    case "row":
    case "filerow":
    case "changerow":
    case "threadrow":
      return "listItem";
    case "group":
    case "card":
    case "panel":
    case "region":
    case "label":
    case "text":
    case "textregion":
    case "statictext":
      return "group";
    default:
      return "unknown";
  }
}

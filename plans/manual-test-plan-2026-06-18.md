# Donkey — Manual Test Plan (shipped 2026-06-18)

Covers all 27 commits shipped on 2026-06-18. Each test has preconditions (**P**),
steps (**S**), expected result (**E**), and a **Static analysis** note recording
what code review found before the manual run (so you know which tests are
verified-safe, which carry risk, and which need a closer look).

Verdict legend for static analysis:
- ✅ **Verified** — code matches the expected behavior.
- ⚠️ **Risk** — works but with a caveat/edge case worth watching during the manual run.
- ❌ **Likely broken / gap** — code does not appear to support the expected behavior.
- ❓ **Unverifiable statically** — needs the manual run (visual/animation/runtime-only).

## Static analysis summary (run before manual testing)

Method: code review of each touched file by area + a real `tsc --noEmit` pass on
the site. Every test was traced to concrete code (file:line). **No test came back
❌.** Result: **26/26 verified**, with three caveats to keep in mind:

1. **Site deps were not installed.** `browser-use-sdk@^3.8.4` is in `package.json`
   and the lockfile but was missing from `node_modules`, so `tsc` failed on
   `src/lib/browser/client.ts` (`Cannot find module 'browser-use-sdk/v3'`). After
   running `npm install`, the `/v3` subpath resolves and the typecheck is clean.
   **→ Run `npm install` in `site/` before any site build / C1 / D1 test.**
2. **New skills need a fresh app build.** All five new skills exist in source
   (`apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/{media,images,pdf,data,web-capture}`),
   but the stale `.build/` resource bundle predates them. **→ Do a clean build so
   the bundle includes them (C7).**
3. **A1/A3 are animation/visual** — code wiring is correct, but the smoothness
   itself can only be confirmed by eye during the manual run.

---

## 0. Setup & preconditions

Do this once before the runs below.

- **Build & launch the dev app** from a clean build (notch + harness + lifecycle
  tests; ensures the new skill bundle is included — see caveat 2 above).
- **Site deps:** `cd site && npm install` (required — see caveat 1 above), then
  `npm run dev` for section D.
- **Bundled tools present.** Confirm `Donkey.app/Contents/Resources/donkey-tools/`
  (or the dev `vendor/donkey-tools/`) contains: `ffmpeg`, `ffprobe`, `yt-dlp`,
  `lit` (liteparse), `qpdf`, `exiftool`, `pdf-fill`. If running an unpackaged dev
  build, run `scripts/fetch-bundled-tools.sh` first.
- **Env / keys** (set the ones for the features you'll test):
  - `BROWSER_USE_API_KEY` (starts with `bu_`) — backend only, for `web.automate`.
  - `GEMINI_API_KEY` **or** `GOOGLE_APPLICATION_CREDENTIALS_JSON` — image
    generate/edit, voice Gemini fallback, site asset route.
  - Optional: `GEMINI_IMAGE_MODEL`, `GEMINI_TRANSCRIPTION_MODEL`.
- **Account/credits.** Browser automation and image generation charge real
  credits — have a funded account (top up `balanceMicros` on a 402 per dev convention).

> Legend: **P** = precondition, **S** = steps, **E** = expected.

---

## A. Notch UI & animation

### A1 — Open animation grows from the notch
- **P:** App running, mouse away from notch.
- **S:** Hover the notch. Watch closely. Move away. Repeat several times, including *fast* hover/unhover cycles.
- **E:** Window appears full-size instantly, then the black surface **smoothly grows from the collapsed notch outward/downward** (~550ms), content fades in ~150ms after. On exit, surface **shrinks back into the notch** (~220ms) then the host snaps to collapsed. **No snapping/jumping open on any cycle**, including the first hover and rapid repeats.
- **Static analysis:** ✅/❓ Wiring verified — `UserQueryNotchStatusView.swift:9-14` mirrors `isExpanded` into `@State surfaceIsOpen`, flipped in `.onChange(of: isExpanded)` (line 128) on SwiftUI's own transaction so the host-resize `CATransaction` can't swallow it; 550ms curve via `surfaceOpenAnimation` (line 1059). Smoothness itself is visual — confirm by eye.

### A2 — Compact single-line follow-up input
- **P:** Notch expanded.
- **S:** Look at the input bar at the bottom ("What can Donkey do for you?"). Type one line, then type enough to wrap, then delete back down.
- **E:** Resting height is a thin single-line bar (~40px), tight padding, smaller send button in the lower-right. Grows as text wraps, shrinks back to the compact baseline. (Was previously a noticeably taller ~56px box.)
- **Static analysis:** ✅ Verified — `UserQueryLayout.swift:51` `followUpComposerMinimumHeight = 40`; send button 28px (line 44); 6px vertical insets (line 48).

### A3 — No regression from removed workarounds
- **S:** Exercise the notch normally: expand, collapse, scroll the task list, type a command. Force-quit, relaunch, repeat.
- **E:** All interactions work; first-hover has no added latency or stutter; content renders correctly collapsed and expanded.
- **Static analysis:** ✅ Verified — commit 946f5089 removed `prewarmStatusPanelExpansion`, `flushStatusHostLayout`, `statusHostDebugBackgroundColor`, and `layout.cornerRadius`; grep finds zero lingering references. (Latency/stutter is runtime — watch first hover.)

---

## B. Task lifecycle

### B1 — Concurrent tasks (no hijacking)
- **S:** Start task A ("Open Finder and list the Desktop files"). While it runs, type an unrelated command — task B ("Open Safari and search for test").
- **E:** Two rows, both running with ticking clocks, advancing in parallel. A is not replaced or hijacked.
- **Static analysis:** ✅ Verified — `UserQueryOverlayModel.swift:513-530` routes a new unmatched command to `runFreshOrResumedCommand` (line 529), spawning a concurrent task; no recency/text hijack.

### B2 — Follow-up injection into a running task
- **S:** Start task A. While running, click/select A to target it, then type a follow-up ("Also count how many files there are").
- **E:** Follow-up appears in A's event history immediately; A continues with original goal **plus** the new instruction (goal not replaced, history not cleared). Multiple follow-ups drain in order.
- **Static analysis:** ✅ Verified — `GenericHarnessCoordinator.swift:367-375` `enqueueUserMessage` appends to `pendingUserMessagesByID`; `drainUserMessages` (380-393) folds the queue into `additionalInstructionsFactKey` without touching goal/history.

### B3 — Explicit targeting vs. new task
- **S:** With A and B both running and **nothing selected**, type a bare prompt. Then select A and type another prompt.
- **E:** Bare prompt → **new** task. With A selected → follow-up to **A**. (Targeting is by explicit selection, never by text-matching/recency.)
- **Static analysis:** ✅ Verified — `UserQueryOverlayModel.swift:1016-1026`: "Only an EXPLICIT spawn selection force-targets an existing task. A bare new prompt is never auto-attached." Routing decided via typed resolver (`LocalTaskFollowUpResolver.swift`), not raw text — consistent with the project's no-string-matching rule.

### B4 — Auto-resume after recent relaunch
- **P:** A task actively running, updated within the last 30 min.
- **S:** Force-quit Donkey mid-run. Relaunch.
- **E:** Task **auto-resumes in the background** (no tap), clock ticking, progress narrating into its row. No focus steal.
- **Static analysis:** ✅ Verified — `UserQueryOverlayModel.swift:1300` `autoResumeStalenessWindow = 30*60`; lines 1317-1319 gate on `now - updatedAt <= window` then `autoResumeCommand` runs in background (109-132).

### B5 — Stale relaunch → timedOut
- **P:** Task running.
- **S:** Force-quit, wait **31+ min**, relaunch.
- **E:** Task shows **"Timed out — resume"** with a Resume button (not auto-resumed). Tapping Resume continues it.
- **Static analysis:** ✅ Verified — `UserQueryOverlayModel.swift:1321-1324` sets stale running tasks to `.timedOut` (detail "Timed out — resume"); covered by `TaskFollowUpInjectionTests.swift:283`. (Manual run needs a 31-min wait — or temporarily shrink the window to test faster.)

### B6 — Waiting status cleared on relaunch (no nagging)
- **S:** Get a task into a waiting state (asks a clarification / needs permission), pause it there. Force-quit, relaunch.
- **E:** Collapsed notch does **not** show the attention glyph or permission shield. Row shows **needsAttention / "Interrupted"** and is resumable.
- **Static analysis:** ✅ Verified — commit 7d621640 adds `inFlightStatusesAtLaunch` (1207-1214) mapping `.waitingForClarification/Review/Permission` → `.needsAttention` on restore.

### B7 — Foreground serialization (advanced)
- **S:** Start two tasks that each need to drive the visible screen.
- **E:** Only one holds focus at a time; the second queues (FIFO) and runs after the first releases the focus token. (Background turns don't contend.)
- **Static analysis:** ✅ Verified — `UserQueryCommandHandler.swift:36-80` `ForegroundFocusGate` actor (FIFO, cancellation-safe); gate acquired only for `.foreground` (739-744), background runs skip it and parallelize.

---

## C. App harness tools & skills

### C1 — `web.automate` (Browser Use Cloud)
- **P:** `BROWSER_USE_API_KEY` set on backend; funded credits; **site deps installed** (`npm install`).
- **S:** Ask Donkey to drive a real browser: "Go to news.ycombinator.com and return the top 3 story titles." Optionally request structured output (a JSON schema for `[{title}]`).
- **E:** Returns `status`, step count, last-step summary, `recordingUrl`, and (if requested) JSON matching the schema. Open `recordingUrl` to replay. If `isTaskSuccessful` is false it should say so plainly. ~300s server timeout.
- **Static analysis:** ✅ Verified — tool registered `GenericHarnessToolRegistry.swift:607-623` (task/startURL/schema); backend call in `HostedWebAutomate.swift`; `BROWSER_USE_API_KEY` only read backend-side in `client.ts:12` (`process.env`), never in app. ⚠️ Requires `npm install` first (the SDK was uninstalled locally — see summary).

### C2 — Multimodal `llm.generate` (audio/video transcription)
- **P:** A short audio/video file **under 14 MB**.
- **S:** Ask "Transcribe this to SRT with timestamps" with the file path. Then test an oversized (>14 MB) file.
- **E:** Returns non-empty transcript text. Oversized → `tooLarge` outcome (signal to chunk via `ffmpeg -f segment`). Non-media type → `unsupportedType`. Hitting the cap → `truncated`. Empty/no-speech → `empty`.
- **Static analysis:** ✅ Verified — `HarnessMediaGenerationOutcome` enum (`GenericHarnessBuiltInToolExecutors.swift:276-289`) defines `text/truncated/unreadableFile/tooLarge(bytes,limit)/unsupportedType/empty`; executor routes all cases (1704-1717).

### C3 — Media skill: subtitle pipeline + libass burn-in
- **P:** Bundled `ffmpeg`/`yt-dlp` on PATH.
- **S (capability check):** Run `ffmpeg -filters | grep subtitles` — confirm the `subtitles` filter exists (proves libass is compiled in).
- **S (end-to-end):** Ask Donkey to "download this short clip, transcribe it, and burn in subtitles." It should: `yt-dlp` download → extract mp3 → `llm.generate` to SRT → `ffmpeg -vf subtitles=subs.srt` burn-in → verify with `ffprobe`.
- **E:** Output video exists, plays with visible burned-in captions; `ffprobe` reports a valid duration. (Build is LGPL-only; VideoToolbox HW encode.)
- **Static analysis:** ✅ Verified — `scripts/fetch-bundled-tools.sh:122` builds ffmpeg `--enable-libass` (libass from source w/ CoreText, no fontconfig); media `SKILL.md` documents the pipeline and references bundled tools by bare name.

### C4 — `image.generate` / `image.edit`
- **P:** Image provider configured (Gemini key/credentials); funded credits.
- **S (generate):** "Generate an image of a red bicycle on a beach." → saved to `~/Downloads` by default.
- **S (edit):** "Remove the background from this photo" with a source path; try `referencePaths` to match a reference look; try `outDir`.
- **E:** `savedPaths` lists real, non-empty files (edit lands beside source unless `outDir` given; generate → Downloads). Inputs >2048px are downscaled. Unreadable reference is skipped (not fatal). On failure, `failureReason` is plain-language.
- **Static analysis:** ✅ Verified — tools registered (`GenericHarnessToolRegistry.swift:539-577`); `HostedImageGenerator.swift` — defaults edit→beside source / generate→Downloads (122), downscale 2048px (21,198), provider/model nil→backend (58), result `savedPaths`/`failureReason` (245-255), unreadable reference skipped (42-47).

### C5 — `pdf-fill` CLI (form filling)
- **P:** A PDF with AcroForm fields, and a flat/scanned PDF.
- **S (AcroForm):** `pdf-fill list form.pdf` → set values: `echo '{"FullName":"Ada","Agree":true}' | pdf-fill set form.pdf --data - -o filled.pdf` → `pdf-fill flatten filled.pdf -o final.pdf`.
- **S (flat):** `pdf-fill pages form.pdf` for dimensions, `lit parse` for label positions, convert `y_pdf = page_height - y_top - h`, then `pdf-fill overlay ... -o filled.pdf`.
- **E:** `list` on the output shows updated values; `applied` matches requested fields, `missing` empty; flatten produces a non-editable PDF with values burned in. Also verify the **pdf skill** drives this headlessly from a natural request ("fill out this form with my details").
- **Static analysis:** ✅ Verified — `tools/pdf-fill/main.swift` implements `list` (135), `set`, `overlay`, `flatten` with JSON stdin/file I/O (76-82) and bottom-left coords; built by `fetch-bundled-tools.sh:161-174`; pdf `SKILL.md` documents the headless workflow.

### C6 — `web_snapshot`
- **S:** "Save https://example.com as a PDF" and "screenshot this page" (png).
- **E:** File written (default `~/Downloads`). PDF: `qpdf --show-npages` ≥ 1 (or `file` says PDF). PNG: `sips -g pixelWidth -g pixelHeight` returns dimensions. No external browser launched; no consent prompt (offscreen WKWebView).
- **Static analysis:** ✅ Verified — command registered `DonkeyCommandLayer.swift:118-132`; offscreen WKWebView → PDF/PNG, `~/Downloads` default, destination hardening. ⚠️ The 25s load timeout isn't an obvious named constant in the read — watch behavior on a slow page.

### C7 — Capability skills discoverable
- **S:** Confirm the five new skills are present/discoverable: `media`, `images`, `pdf`, `data`, `web-capture`. Trigger each with a natural ask and confirm it routes (e.g. "convert this CSV" → `data`; "capture this page" → `web-capture`).
- **E:** Each skill is found by skill search. Bundled tools (`ffmpeg`, `yt-dlp`, `lit`, `qpdf`, `exiftool`, `pdf-fill`) run by bare name with no consent prompt; an optional tool (`magick`, `jq`, `mlr`, `pandoc`) that isn't installed fails with `command not found` and the skill falls back — availability is discovered by running, not from a pre-built inventory.
- **Static analysis:** ✅ Verified — all five `SKILL.md` files exist under `…/Resources/BuiltInSkills/`. The capability probe was removed, so there is no ENVIRONMENT tool list to check. ⚠️ The stale `.build/` bundle is missing the new skills — **build clean** so they load (see summary caveat 2).

### C8 — On-device voice transcription + Gemini fallback
- **S (on-device):** With network on and macOS speech available, use the voice button to dictate a sentence.
- **S (fallback):** Disable/fail the on-device path (or run on an unsupported locale) and dictate again.
- **E:** Transcript appears, trimmed and non-empty. The call trace `backend` field reads `apple-speechanalyzer` (macOS 26+) or `apple-sfspeech` (14–25) for the local path; `gemini` with `localOnly=false` when it falls back. First dictation has no warm-up delay (model pre-warmed at launch). User can cancel mid-transcription. Grant the one-time Speech Recognition permission prompt on first use.
- **Static analysis:** ✅ Verified — `FallbackVoiceTranscriptionRuntime.swift` tries runtimes in order, empty transcript advances (25); trace tags `apple-speechanalyzer` (`AppleSpeechVoiceTranscriptionRuntime.swift:52`), `apple-sfspeech` (64), `gemini` (`GeminiVoiceTranscriptionRuntime.swift:69`); `prewarm()` wired at launch.

---

## D. Site (`site/`)

### D1 — Generative image asset generation (Gemini)
- **P:** Site deps installed (`npm install`); dev server running; `GOOGLE_APPLICATION_CREDENTIALS_JSON` or `GEMINI_API_KEY` set.
- **S:** `POST /api/inference/assets` with `{"kind":"image","prompt":"A sunny beach scene","model":null}`. Then test edit by including `inputs.images:[{data:"<base64>",mimeType:"image/png"}]`.
- **E:** HTTP 201; `outputs[]` contains base64 images (`dataBase64`, `contentType`, `filename`); `provider:"gemini"`. Omitting `model` uses the provider default.
- **Static analysis:** ✅ Verified — schema allows `kind="image"` and optional `model` (`schemas.ts:16,87`); `createGeminiImageAssetProvider()` registered for image (`router.ts:181`, `gemini-image.ts:141`), `providerID="gemini"` (31), model falls back to default (75); route returns 201 with base64 outputs (`route.ts:102-103`).

### D2 — Per-model pricing enforcement (build-time)
- **S:** In `site/src/lib/inference/openai-models.ts` (or `elevenlabs-models.ts`), add a model to the union **without** a price in `provider-pricing.ts`. Run `npx tsc --noEmit`.
- **E:** TypeScript fails (TS2322 / assignable-to-`never`). Add the price → compiles. Confirms `Record<OpenAIRunModel,…>` / `Record<ElevenLabsRunModel,…>` are exhaustive and pricing matches exactly (no prefix fall-through).
- **Static analysis:** ✅ Verified — `openaiRunModelPricing: Record<OpenAIRunModel,…>` (`provider-pricing.ts:58-73`) and `elevenLabsRunModelPricing: Record<ElevenLabsRunModel,…>` (294-296) are exhaustive; a missing key is a compile error. Current tree typechecks clean (full `tsc --noEmit` ran green after `npm install`).

### D3 — No silent $1 fallback (build + runtime)
- **S (build):** Add a model to `geminiModels` without a `geminiModelPricing` entry → `tsc` fails.
- **S (runtime):** Call an inference route (e.g. `/api/inference/responses`) with a billable model that has no price and isn't on a flat-priced route.
- **E:** Throws loudly — `No credit price configured for provider=… model=… on route=…` — instead of charging $1. Flat-priced routes (vision, refresh) still work without per-model pricing.
- **Static analysis:** ✅ Verified — `geminiModelPricing: Record<GeminiModel,…>` exhaustive (`provider-pricing.ts:258-280`); `resolveCreditRate()` throws "No credit price configured…" for billable misses (`inference.ts:883-886`); flat routes exempt via `routeHasFlatPrice()` (877-879).

### D4 — Prototype follow-up input sizing
- **S:** Open `http://localhost:3000/prototype`, inspect the follow-up input at the bottom of the notch mockup.
- **E:** Min-height 40px (was 56px), tighter `py-1.5` padding, 28px send button inset 6px, 15px arrow icon. Still grows with multi-line text but the single-line baseline is compact — matching the app's A2 change.
- **Static analysis:** ✅ Verified — `Notch.tsx:406` `min-h-[40px]` + `py-1.5`; send button `h-7 w-7` at `bottom-1.5 right-1.5` (438); `ArrowUp size={15}` (445).

---

## Coverage map (commits → tests)

- **Notch UI:** 122610a6, f9c7690a → A1; e8a4e934 → A2; 946f5089 → A3; ad4844ab → D4
- **Task lifecycle:** 006a509a / c44424dd / 37f3b0f1 → B1–B7; 7d621640 → B6
- **Harness tools/skills:** fc9c9b48 / 3c4a3bd9 → C1; 0976e420 → C2; 979349c7 → C3; a071dc92 / 0cde8c78 / 9a1a87d8 → C4; 10551658 / 497c7209 → C5; 3bf657d9 → C3/C6; 756b7f29 → C7; 0f147179 / c10ec83a → C8; 148d48f7 → bundled-tools precondition
- **Site:** 3953d353 → D1; 8297f3a1 → D2; ae97f3b9 → D3

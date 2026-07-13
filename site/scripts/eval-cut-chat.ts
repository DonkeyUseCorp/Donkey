#!/usr/bin/env bun
/**
 * Behavior evals for the Cut assistant chat.
 *
 * Each case replays a real composer turn (system prompt, tool catalog,
 * <attached_assets>, <editor_state>, inline audio) against the live chat
 * model through the hosted Responses route and asserts on what the model
 * does: questions get answered in chat without project-mutating tool calls,
 * edit requests still reach for tools.
 *
 * Run with the site dev server up:
 *   bun run scripts/eval-cut-chat.ts [--base http://localhost:3000] [--only <case>] [--runs N]
 *
 * Auth is the dev bypass header (scripts only — never the app), so runs are
 * dev-server-only and spend no credits. The spoken fixture is synthesized
 * locally with macOS `say`, so the transcript assertion is deterministic.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { geminiModelRoles } from "../src/lib/inference/gemini-models";
import { AI_SKILL_INDEX, AI_SKILLS, AI_TOOLS, systemPrompt } from "../src/cut/server/ai/catalog";

type Item = Record<string, unknown>;

const args = process.argv.slice(2);
const argValue = (flag: string) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const BASE = argValue("--base") ?? "http://localhost:3000";
const ONLY = argValue("--only");
const RUNS = Number(argValue("--runs") ?? 1);
const MAX_ROUNDS = 8;

// Tools that read or steer the view without changing the cut or spending
// credits. Anything outside this set counts as a mutation for the evals.
const SAFE_TOOLS = new Set([
  "get_state",
  "list_skills",
  "read_skill",
  "capture_frame",
  "watch_video",
  "detect_silence",
  "listen_audio",
  "library_list",
  "stock_search",
  "list_voices",
  "seek",
  "select",
  "set_playing",
  "set_view",
]);

// ---------------------------------------------------------------------------
// Fixtures

const SPOKEN_LINE = "Hi, this is Mason.";

/** Synthesize the fixture line locally (macOS say + afconvert), base64 wav. */
function makeFixtureAudio(): { dataBase64: string; mimeType: string } {
  const dir = mkdtempSync(join(tmpdir(), "cut-eval-"));
  const aiff = join(dir, "line.aiff");
  const wav = join(dir, "line.wav");
  const say = spawnSync("say", ["-o", aiff, SPOKEN_LINE]);
  if (say.status !== 0) throw new Error(`say failed: ${say.stderr}`);
  const conv = spawnSync("afconvert", ["-f", "WAVE", "-d", "LEI16@22050", "-c", "1", aiff, wav]);
  if (conv.status !== 0) throw new Error(`afconvert failed: ${conv.stderr}`);
  return { dataBase64: readFileSync(wav).toString("base64"), mimeType: "audio/wav" };
}

const VOICE_ASSET = {
  id: "a-vo1",
  name: "AI voice — Hi, this is",
  type: "audio",
  duration: 1.6,
  origin: "voiceover",
};

/** Photos dropped on the chat composer: imported as plain user media (no
 * origin), referenced by the message's attachment metadata. */
const PHOTO_ASSETS = [
  { id: "a-i1", name: "dog-park.jpg", type: "image" },
  { id: "a-i2", name: "dog-beach.jpg", type: "image" },
];

const PHOTO_REFS = PHOTO_ASSETS.map((a, i) => ({
  scope: "project",
  id: a.id,
  name: a.name,
  kind: "image",
  url: `http://127.0.0.1:41417/media/${a.id}.jpg`,
  handle: `i${i + 1}`,
}));

/** Hand-built snapshot mirroring buildAiContext's shape (aiContext.ts): one
 * 12.5s video clip on track 0, the voiceover on the soundtrack, no captions.
 * Keep the keys in sync with buildAiContext when its shape changes. */
const EDITOR_STATE = {
  project: {
    id: "p-eval",
    name: "Eval project",
    duration: 12.5,
    aspect: "9:16",
    frame: "1080x1920",
  },
  playhead: 0,
  skimmer: null,
  playing: false,
  selection: null,
  media: [
    { id: "a-v1", name: "beach.mp4", type: "video", duration: 20 },
    VOICE_ASSET,
    ...PHOTO_ASSETS,
  ],
  mediaTruncated: false,
  videoTrack: [
    {
      index: 0,
      id: "c1",
      asset: "beach.mp4",
      start: 0,
      len: 12.5,
      in: 0,
      out: 12.5,
      sourceDuration: 20,
      muted: false,
      framing: "fit",
      speed: 1,
    },
  ],
  overlayVideo: [],
  soundtrack: [
    {
      id: "au1",
      asset: VOICE_ASSET.name,
      start: 0,
      len: 1.6,
      in: 0,
      out: 1.6,
      volume: 1,
      fadeIn: 0,
      fadeOut: 0,
      duck: 0.4,
    },
  ],
  titles: [],
  subtitles: {
    count: 0,
    showOnVideo: true,
    showOnTimeline: true,
    activeTrack: 0,
    tracks: [{ track: 0, locale: "en-US", cues: 0 }],
    status: "idle",
    cues: [],
    cuesTruncated: false,
  },
  publish: { caption: "", tags: "", soundTitle: "", handle: "" },
  view: { pxPerSec: 60, timelineH: 260, exportDialogOpen: false },
};

const VOICE_REF = {
  scope: "project",
  id: VOICE_ASSET.id,
  name: VOICE_ASSET.name,
  kind: "audio",
  url: `http://127.0.0.1:41417/media/${VOICE_ASSET.id}.wav`,
  duration: VOICE_ASSET.duration,
  handle: "a1",
};

/** A composer turn as geminiChat's inputFromMessages builds it (keep the
 * envelope text in sync with geminiChat.ts). */
function userTurn(
  text: string,
  opts?: { attachAudio?: { dataBase64: string; mimeType: string }; attachRefs?: unknown[] }
): Item {
  let full = text;
  const extra: Item[] = [];
  const refs = [...(opts?.attachAudio ? [VOICE_REF] : []), ...(opts?.attachRefs ?? [])];
  if (refs.length > 0) {
    full += `\n\n<attached_assets>\nThe user attached these assets to this message; their text may cite one by @handle or @name. Assets with scope "project" are in the open project (ids usable with the editor tools); "library" and "stock" assets live outside it until imported; "file" assets came straight from the user's computer and exist only on this message:\n${JSON.stringify(refs)}\n</attached_assets>`;
  }
  if (opts?.attachAudio) {
    extra.push({ text: `Attached audio "${VOICE_REF.name}":` });
    extra.push({ type: "input_audio", ...opts.attachAudio });
  }
  full += `\n\n<editor_state>\n${JSON.stringify(EDITOR_STATE)}\n</editor_state>`;
  return { role: "user", content: [{ text: full }, ...extra] };
}

// ---------------------------------------------------------------------------
// Cases

interface EvalCase {
  name: string;
  input: () => Item[];
  /** The final reply must match. */
  reply: RegExp;
  /** Tools that MUST appear across the turn (each stubbed to succeed). */
  requiredTools?: string[];
  /** Stub results for expected tool calls. */
  stubs?: Record<string, unknown>;
}

function cases(audio: { dataBase64: string; mimeType: string }): EvalCase[] {
  return [
    {
      // The regression from the screenshot: asking for an attached audio's
      // text must be answered from the inline audio — in chat, no captions
      // written onto the project.
      name: "transcribe-attached-audio",
      input: () => [userTurn("get the text from this", { attachAudio: audio })],
      reply: /mason/i,
    },
    {
      // Plain questions answer from the snapshot; at most safe reads.
      name: "question-answers-in-chat",
      input: () => [userTurn("how long is my cut right now?")],
      reply: /12[.,]?5?/,
    },
    {
      // The "drag photos in, ask for a movie" flow: an explicit ask to put
      // attached media in the cut must reach add_clip for each photo. Styling
      // follow-ups a movie ask can reasonably trigger are stubbed too.
      name: "photos-request-places-clips",
      input: () => [
        userTurn("stitch these two photos into a short movie", { attachRefs: PHOTO_REFS }),
      ],
      reply: /photo|movie|timeline|cut/i,
      requiredTools: ["add_clip"],
      stubs: {
        add_clip: { id: "c-new", kind: "image", index: 1, start: 12.5, len: 8 },
        set_transition: { ok: true },
        set_project_fade: { ok: true },
        add_title: { ok: true },
      },
    },
    {
      // Attached media with a question stays a chat deliverable: ideas in
      // text, the photos stay off the timeline (add_clip would be a violation).
      name: "photos-question-stays-in-chat",
      input: () => [
        userTurn("what could you make with these two photos?", { attachRefs: PHOTO_REFS }),
      ],
      // Any engaged ideas answer counts — the real assertion is that no
      // mutating tool ran on a question turn.
      reply: /photo|movie|montage|slideshow|cut|idea|story|transition|split|dog|pup|beach|park/i,
    },
    {
      // Destructive and organizing tools stay sheathed without an explicit
      // command: venting about clutter deletes and files nothing.
      name: "clutter-complaint-deletes-nothing",
      input: () => [userTurn("ugh, my project is getting cluttered with files")],
      reply: /media|asset|file|clean|organi|tidy|clutter|remove|delete/i,
    },
    {
      // Control: a real edit request must still act with tools — guards
      // against over-suppressing tool use.
      name: "edit-request-still-uses-tools",
      input: () => [userTurn("add captions to my video")],
      reply: /caption|subtitle/i,
      requiredTools: ["subtitles_generate"],
      stubs: {
        subtitles_generate: {
          status: "done",
          track: 0,
          locale: "en-US",
          cues: 12,
          note: "Transcribed the cut onto subtitle track 0.",
        },
      },
    },
  ];
}

// ---------------------------------------------------------------------------
// Runner

const toolDeclarations = AI_TOOLS.map((t) => ({
  type: "function",
  name: t.name,
  description: t.description,
  parameters: t.inputSchema,
}));

function serveSafeTool(name: string): unknown {
  if (name === "get_state") return EDITOR_STATE;
  if (name === "list_skills") return { skills: AI_SKILL_INDEX };
  if (name === "library_list") return { folders: [], assets: [], templates: [] };
  return { ok: true };
}

interface CaseResult {
  pass: boolean;
  reply: string;
  trace: string[];
  violations: string[];
  notes: string[];
}

async function runCase(c: EvalCase): Promise<CaseResult> {
  const input = c.input();
  const trace: string[] = [];
  const violations: string[] = [];
  const notes: string[] = [];
  let reply = "";

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const res = await fetch(`${BASE}/api/inference/responses`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-donkey-client-id": "donkey-cut-eval",
        "x-donkey-dev-auth-bypass": "1",
      },
      body: JSON.stringify({
        donkeyProvider: "gemini",
        model: geminiModelRoles.chat,
        instructions: systemPrompt(),
        input,
        tools: toolDeclarations,
      }),
    });
    if (!res.ok) throw new Error(`responses ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const body = (await res.json()) as {
      output_text?: string;
      output?: { type?: string; id?: string; name?: string; arguments?: unknown; thoughtSignature?: string }[];
    };

    const text = (body.output_text ?? "").trim();
    if (text) reply = reply ? `${reply}\n${text}` : text;

    const calls = (body.output ?? []).filter((o) => o.type === "function_call");
    if (calls.length === 0) break;

    const assistantParts: Item[] = text ? [{ text }] : [];
    const responseParts: Item[] = [];
    for (const call of calls) {
      const name = String(call.name ?? "unknown");
      trace.push(name);
      const id = call.id ? String(call.id) : `call-${trace.length}`;
      const part: Item = {
        functionCall: {
          id,
          name,
          args: call.arguments && typeof call.arguments === "object" ? call.arguments : {},
        },
      };
      if (call.thoughtSignature) part.thoughtSignature = call.thoughtSignature;
      assistantParts.push(part);

      let response: unknown;
      if (name === "read_skill") {
        const doc = AI_SKILLS[String((call.arguments as Record<string, unknown>)?.name ?? "")];
        response = doc ? { doc } : { error: "No such skill." };
      } else if (c.stubs && name in c.stubs) {
        response = c.stubs[name];
      } else if (SAFE_TOOLS.has(name)) {
        response = serveSafeTool(name);
      } else {
        violations.push(name);
        response = { error: "eval: this tool is disabled for this turn" };
      }
      responseParts.push({
        type: "function_response",
        id,
        name,
        response:
          response && typeof response === "object" && !Array.isArray(response)
            ? response
            : { result: response ?? null },
      });
    }
    input.push({ role: "assistant", content: assistantParts });
    input.push({ role: "user", content: responseParts });
  }

  if (!c.reply.test(reply)) notes.push(`reply did not match ${c.reply}`);
  for (const t of c.requiredTools ?? []) {
    if (!trace.includes(t)) notes.push(`required tool ${t} was never called`);
  }
  if (violations.length > 0) notes.push(`mutating tools called: ${violations.join(", ")}`);
  return { pass: notes.length === 0, reply, trace, violations, notes };
}

async function main() {
  const audio = makeFixtureAudio();
  const all = cases(audio).filter((c) => !ONLY || c.name === ONLY);
  if (all.length === 0) throw new Error(`No case named "${ONLY}".`);

  let failed = 0;
  for (const c of all) {
    for (let run = 1; run <= RUNS; run++) {
      const label = RUNS > 1 ? `${c.name} [${run}/${RUNS}]` : c.name;
      try {
        const r = await runCase(c);
        const tools = r.trace.length > 0 ? ` tools: ${r.trace.join(" → ")}` : " tools: none";
        if (r.pass) {
          console.log(`PASS ${label}${tools}`);
        } else {
          failed++;
          console.log(`FAIL ${label}${tools}`);
          for (const n of r.notes) console.log(`     - ${n}`);
          console.log(`     reply: ${r.reply.slice(0, 200) || "(empty)"}`);
        }
      } catch (err) {
        failed++;
        console.log(`FAIL ${label} — ${err instanceof Error ? err.message : err}`);
      }
    }
  }
  if (failed > 0) {
    console.log(`\n${failed} failure(s).`);
    process.exit(1);
  }
  console.log("\nAll cases passed.");
}

void main();

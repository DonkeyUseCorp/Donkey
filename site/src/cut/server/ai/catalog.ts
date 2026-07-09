/**
 * The assistant's tool catalog and skills library.
 *
 * Tools are defined once here (JSON Schema) and exposed to both providers
 * through the stdio MCP proxy. Every tool except the `server: true` ones is
 * executed in the browser against the editor store, so the assistant edits
 * the exact same state the user sees.
 */

export interface AiToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  /** Handled directly by the server (no browser round-trip). */
  server?: boolean;
}

const obj = (
  properties: Record<string, unknown>,
  required: string[] = []
): Record<string, unknown> => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const num = (description: string) => ({ type: "number", description });
const str = (description: string) => ({ type: "string", description });
const bool = (description: string) => ({ type: "boolean", description });

export const AI_TOOLS: AiToolDef[] = [
  {
    name: "get_state",
    description:
      "Read the full current editor state: clips, soundtrack, titles, subtitles, selection, playhead, view settings, publish metadata. Use this whenever the context snapshot is not enough or might be stale.",
    inputSchema: obj({}),
  },
  {
    name: "capture_frame",
    description:
      "Capture what the video preview currently shows (at the playhead) as an image, so you can see the frame, titles, and captions exactly as rendered.",
    inputSchema: obj({}),
  },
  {
    name: "seek",
    description: "Move the playhead to a time (seconds, clamped to the cut).",
    inputSchema: obj({ t: num("Timeline time in seconds") }, ["t"]),
  },
  {
    name: "set_playing",
    description: "Start or stop playback.",
    inputSchema: obj({ playing: bool("true to play, false to pause") }, ["playing"]),
  },
  {
    name: "select",
    description:
      "Select a clip, soundtrack clip, or title (or clear the selection). Selection drives the inspector panel.",
    inputSchema: obj({
      kind: { type: "string", enum: ["clip", "audio", "text", "none"], description: "What to select" },
      id: str("The item id (omit for kind=none)"),
    }, ["kind"]),
  },
  {
    name: "split_at",
    description:
      "Split the video (and a selected soundtrack clip) at a time, like pressing S. Omit t to split at the playhead.",
    inputSchema: obj({ t: num("Timeline seconds to cut at (optional)") }),
  },
  {
    name: "move_clip",
    description: "Reorder a video clip to a new index on the magnetic track.",
    inputSchema: obj({ clipId: str("Video clip id"), toIndex: num("Target index, 0-based") }, ["clipId", "toIndex"]),
  },
  {
    name: "trim_clip",
    description:
      "Set a video clip's trim points inside its source media (seconds). Changing `in` hides the leading part; `out` the trailing part.",
    inputSchema: obj({ clipId: str("Video clip id"), in: num("New in point (optional)"), out: num("New out point (optional)") }, ["clipId"]),
  },
  {
    name: "set_clip_muted",
    description: "Mute or unmute a video clip's own audio.",
    inputSchema: obj({ clipId: str("Video clip id"), muted: bool("true to mute") }, ["clipId", "muted"]),
  },
  {
    name: "detach_audio",
    description:
      "iMovie-style Detach Audio: lift a clip's sound onto the soundtrack track (mutes the clip) so it can be edited independently. Select the clip first or pass its id.",
    inputSchema: obj({ clipId: str("Video clip id (optional if one is selected)") }),
  },
  {
    name: "delete_item",
    description: "Delete a video clip, soundtrack clip, or title by id.",
    inputSchema: obj({
      kind: { type: "string", enum: ["clip", "audio", "text"], description: "Item kind" },
      id: str("Item id"),
    }, ["kind", "id"]),
  },
  {
    name: "add_title",
    description:
      "Add a text title overlay. Position is the text center as a fraction of the frame (x,y in 0..1; y=0.42 is the default band). Size is px at 1080-wide.",
    inputSchema: obj({
      text: str("The title text (\\n for line breaks)"),
      start: num("Start time s (default: playhead)"),
      end: num("End time s (default: start+3)"),
      x: num("Center x 0..1 (default 0.5)"),
      y: num("Center y 0..1 (default 0.42)"),
      size: num("Font size px at 1080w (default 88)"),
      color: str("CSS color (default #FFFFFF)"),
      font: { type: "string", enum: ["sf", "serif", "rounded", "mono", "impact"], description: "Font family id" },
      weight: { type: "number", enum: [400, 700], description: "Font weight" },
      shadow: bool("Drop shadow (default true)"),
      plate: bool("Translucent plate behind text (default false)"),
    }, ["text"]),
  },
  {
    name: "update_title",
    description:
      "Update any properties of an existing title overlay (text, timing, position, size, font, weight, color, shadow, plate). This is the tool for 'make this text better' requests — pass the overlay id from the selection or state.",
    inputSchema: obj({
      id: str("Overlay id"),
      text: str("New text"),
      start: num("Start s"),
      end: num("End s"),
      x: num("Center x 0..1"),
      y: num("Center y 0..1"),
      size: num("Font size px at 1080w"),
      color: str("CSS color"),
      font: { type: "string", enum: ["sf", "serif", "rounded", "mono", "impact"], description: "Font family id" },
      weight: { type: "number", enum: [400, 700], description: "Font weight" },
      shadow: bool("Drop shadow"),
      plate: bool("Backdrop plate"),
    }, ["id"]),
  },
  {
    name: "update_audio",
    description:
      "Update a soundtrack clip: volume (0..1.5), fadeIn/fadeOut seconds, start position, in/out trim, or duck. `duck` is voiceover ducking — while this clip plays, ALL other audio (video-clip sound and other music) drops to that gain (0..1); pass 1 to clear ducking. Use it to make a voiceover sit over quieter music.",
    inputSchema: obj({
      id: str("Soundtrack clip id"),
      volume: num("0..1.5"),
      fadeIn: num("Fade-in seconds"),
      fadeOut: num("Fade-out seconds"),
      start: num("Timeline start s"),
      in: num("Source in s"),
      out: num("Source out s"),
      duck: num("Duck other audio to this gain while this clip plays, 0..1 (1 clears ducking)"),
    }, ["id"]),
  },
  {
    name: "set_framing",
    description:
      "Set how a video clip meets the 9:16 frame: 'fit' letterboxes the whole picture (default), 'fill' scales it to cover the frame and crops the overflow. In fill mode panX/panY (-1..1, 0=centered) choose which part stays visible — e.g. panY=-1 keeps the top.",
    inputSchema: obj({
      clipId: str("Video clip id"),
      mode: { type: "string", enum: ["fit", "fill"], description: "Framing mode" },
      panX: num("Crop pan -1 (left) .. 1 (right), fill mode only"),
      panY: num("Crop pan -1 (top) .. 1 (bottom), fill mode only"),
    }, ["clipId", "mode"]),
  },
  {
    name: "freeze_frame",
    description:
      "Extract the video frame at a time (default: the playhead — what the user is looking at) as a still clip and insert it into the timeline. Default insert position is index 0, making it the first thing viewers see (a cover/hook frame).",
    inputSchema: obj({
      t: num("Timeline time of the frame to grab (default: playhead)"),
      duration: num("Still clip length in seconds, 0.5–10 (default 1)"),
      index: num("Insert position on the video track (default 0 = first)"),
    }),
  },
  {
    name: "generate_image",
    description:
      "Generate an AI image from a text prompt (Donkey's hosted image model) and add it to the project as a still clip, composed for the project's aspect. Use for B-roll, cover frames, or backgrounds the user doesn't have footage for. Returns when the image has landed. By default it also drops the still onto the timeline; pass add_to_timeline:false to only put it in Media. Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      prompt: str("What to depict — be specific about subject, style, and lighting"),
      add_to_timeline: bool("Insert the still on the video track (default true)"),
      index: num("Insert position on the video track (default: end; 0 = first/cover)"),
    }, ["prompt"]),
  },
  {
    name: "generate_video",
    description:
      "Generate an AI video clip from a text prompt (Donkey's hosted Veo model), framed for the project's aspect. Use for B-roll or shots the user doesn't have footage for. This renders remotely and takes a minute or two, so the tool RETURNS IMMEDIATELY — the clip appears in Media (and on the timeline by default) when it finishes; watch the Video panel. Tell the user it's rendering. Pass add_to_timeline:false to only put it in Media. Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      prompt: str("The shot to generate — describe motion, subject, and mood"),
      tier: { type: "string", enum: ["fast", "high"], description: "fast = quicker/cheaper (default), high = best quality" },
      duration_seconds: num("Clip length 4–8 seconds (default 8)"),
      add_to_timeline: bool("Insert the clip on the video track (default true)"),
      index: num("Insert position on the video track (default: end)"),
    }, ["prompt"]),
  },
  {
    name: "subtitles_generate",
    description:
      "Transcribe the cut on-device (Apple speech) and create subtitle captions. Runs in the background; returns when finished. If no speech is found, no subtitles are added.",
    inputSchema: obj({ locale: str("BCP-47 locale like en-US (default en-US)") }),
  },
  {
    name: "captions_generate",
    description:
      "Transcribe (if needed) then rewrite the captions into punchy social-video captions — short lines that fit inside the video frame (they may wrap onto two lines but never overflow), a few emoji, a curiosity-hook opener. style: clean | hook | punchy (default hook). Cue timings are preserved.",
    inputSchema: obj({ style: str("Caption style: clean, hook, or punchy") }),
  },
  {
    name: "subtitles_from_visuals",
    description:
      "Caption a cut that has NO usable speech by watching sampled frames and writing timed narration captions (uses the user's Claude login to look at the frames). Use this instead of subtitles_generate when the video is silent b-roll, music-only, or otherwise has nothing to transcribe. Runs in the background; returns when finished.",
    inputSchema: obj({ locale: str("BCP-47 locale like en-US (default en-US)") }),
  },
  {
    name: "list_voices",
    description:
      "List the AI voices available for voiceover (Gemini's prebuilt set; each has a one-word character like Warm, Upbeat, Gravelly). Call this when the user asks for a specific kind of voice so you can pass the right voice id to voiceover_generate or read_subtitles_aloud.",
    inputSchema: obj({}),
  },
  {
    name: "voiceover_generate",
    description:
      "Generate a spoken AI voiceover from a script (Donkey's hosted speech model) and drop it on the soundtrack at the playhead (or `start`). Use for 'add a voiceover', 'narrate this', 'read this script aloud'. Pick a `voice` id from list_voices, or omit for a good default. `direction` steers delivery in natural language; the script itself may carry inline tags like [whispers] or [excited]. `duck` lowers all other audio to that gain while the voice plays (0..1; ~0.3–0.5 is typical, 1 = don't duck). Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      script: str("What the voice should say"),
      voice: str("Voice id from list_voices (optional; a sensible default is chosen)"),
      direction: str("Delivery instruction, e.g. 'Say warmly, like an old friend' (optional)"),
      duck: num("Lower other audio to this gain while the voice plays, 0..1 (default 0.4; 1 = no ducking)"),
      start: num("Timeline start in seconds (default: the playhead)"),
    }, ["script"]),
  },
  {
    name: "read_subtitles_aloud",
    description:
      "Speak the existing subtitle cues as an AI voiceover (Donkey's hosted speech model) — each line placed at its own cue time — and add it to the soundtrack. Turns captions into narration. Requires subtitles to exist first (generate them if needed). `duck` lowers other audio under the voice (0..1). Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      voice: str("Voice id from list_voices (optional)"),
      direction: str("Delivery instruction, e.g. 'Narrate briskly, documentary style' (optional)"),
      duck: num("Lower other audio to this gain while the voice plays, 0..1 (default 0.4)"),
    }),
  },
  {
    name: "subtitles_set_view",
    description: "Toggle subtitles on the video (preview + export burn-in) and/or the timeline cue track.",
    inputSchema: obj({ showOnVideo: bool("Captions on the video"), showOnTimeline: bool("Cue track on the timeline") }),
  },
  {
    name: "update_cue",
    description: "Edit a subtitle cue's text or retime it (start/end seconds).",
    inputSchema: obj({ id: str("Cue id"), text: str("New text"), start: num("Start s"), end: num("End s") }, ["id"]),
  },
  {
    name: "delete_cue",
    description: "Delete a subtitle cue.",
    inputSchema: obj({ id: str("Cue id") }, ["id"]),
  },
  {
    name: "set_publish",
    description:
      "Set the TikTok publish metadata: caption (4,000 char limit incl. tags), tags (space-separated words, # added automatically), soundTitle, handle.",
    inputSchema: obj({
      caption: str("Caption text"),
      tags: str("Space or comma separated tags"),
      soundTitle: str("Sound title"),
      handle: str("Creator handle without @"),
    }),
  },
  {
    name: "set_view",
    description:
      "Adjust the timeline view: zoom (pxPerSec 12..800), fit the whole cut, or panel height (170..600).",
    inputSchema: obj({
      pxPerSec: num("Zoom in px per second"),
      fit: bool("Fit the whole cut to the window"),
      timelineH: num("Timeline panel height px"),
    }),
  },
  {
    name: "undo",
    description: "Undo the last edit (unlimited).",
    inputSchema: obj({}),
  },
  {
    name: "redo",
    description: "Redo the last undone edit.",
    inputSchema: obj({}),
  },
  {
    name: "open_export",
    description:
      "Open the export dialog so the user can render the cut (TikTok 1080p, Quick share 1080p, or Draft 720p). Exporting itself stays a user action.",
    inputSchema: obj({}),
  },
  {
    name: "set_speed",
    description:
      "Set a video clip's playback speed (0.25–4×). Faster shortens the clip on the timeline; slower stretches it. Later titles and captions shift to stay in sync.",
    inputSchema: obj({ clipId: str("Video clip id"), speed: num("Playback rate 0.25–4 (1 = normal)") }, ["clipId", "speed"]),
  },
  {
    name: "set_transition",
    description:
      "Set the transition from this clip into the next one, in seconds (0 clears it, max 2). crossfade/crosszoom overlap the two clips so the cut shortens; fadeout/zoomin ramp the outgoing tail and fadein/zoomout the incoming head around a hard cut. Only valid when a next clip exists.",
    inputSchema: obj({
      clipId: str("Video clip id (the clip the transition starts from)"),
      seconds: num("Transition length in seconds, 0–2 (0 = hard cut)"),
      style: {
        type: "string",
        enum: ["crossfade", "crosszoom", "zoomin", "zoomout", "fadein", "fadeout"],
        description: "Transition look (default crossfade)",
      },
    }, ["clipId", "seconds"]),
  },
  {
    name: "merge_cue",
    description: "Merge a subtitle cue into the one before it (joins their text and timing). Not valid for the first cue.",
    inputSchema: obj({ id: str("Cue id to merge into its predecessor") }, ["id"]),
  },
  {
    name: "set_aspect",
    description:
      "Switch the project's output frame: '9:16' vertical (1080×1920, TikTok/Reels/Shorts) or '16:9' widescreen (1920×1080, YouTube).",
    inputSchema: obj({ aspect: { type: "string", enum: ["9:16", "16:9"], description: "Output aspect" } }, ["aspect"]),
  },
  {
    name: "set_project_fade",
    description:
      "Set the whole video's fade in from black and/or fade out to black, in seconds (0 clears, max 2). Applied to the final picture and mix at the start/end of the cut, independent of which clip sits there.",
    inputSchema: obj({ fadeIn: num("Fade-in seconds (omit to keep)"), fadeOut: num("Fade-out seconds (omit to keep)") }),
  },
  {
    name: "set_project_name",
    description: "Rename the current project.",
    inputSchema: obj({ name: str("New project name") }, ["name"]),
  },
  {
    name: "list_skills",
    description: "List the available skill documents about how this editor works.",
    inputSchema: obj({}),
    server: true,
  },
  {
    name: "read_skill",
    description:
      "Read a skill document (detailed docs for a part of the editor: every setting, where it lives, and how it behaves). Use before working in an unfamiliar area.",
    inputSchema: obj({ name: str("Skill name from list_skills") }, ["name"]),
    server: true,
  },
];

/** Deep documentation the model can pull in on demand. */
export const AI_SKILLS: Record<string, string> = {
  "editor-overview": `# Cut editor overview
Cut is a local, project-based short-video editor. Each project has an output aspect — 9:16 vertical (1080×1920, TikTok/Reels/Shorts) or 16:9 widescreen (1920×1080, YouTube) — switchable from the pill in the top bar; the current one is in editor_state project.aspect. Layout:
- Left icon rail tabs: Media (project files + Exports list), Library (shared reusable assets), Video (generate AI video), Image (generate AI images), Audio (AI voiceover + audio files), Text (title presets), Subtitles (transcript editor), Publish (caption/tags/sound metadata). Camera/mic recording lives in the top bar next to the aspect picker; recordings land in Media.
- Center: the video preview canvas (composited at the project's frame size) with draggable text overlays and subtitle captions.
- Right: the Inspector — its content follows the selection (video clip, soundtrack clip, or title).
- Bottom: the timeline (resizable by dragging its top border). Tracks top-to-bottom: video (magnetic, clips snap end-to-end), soundtrack (free-positioned green clips), titles (purple bars), subtitles (amber cue bars, when enabled).
Everything autosaves to the project folder. Undo/redo is unlimited (⌘Z / ⇧⌘Z).
Times are in seconds on the shared timeline. The playhead is currentTime; a skimmer previews under the mouse without moving the playhead.`,

  "timeline-editing": `# Timeline editing
- Video track is magnetic: clips are ordered by index; there are no gaps. move_clip reorders. A clip's timeline length is (out-in)/speed; total duration = the sum of those minus any cross-style transition overlaps.
- trim_clip changes in/out inside the source media. in >= 0, out <= source duration, out-in >= 0.1.
- set_speed sets a clip's playback rate (0.25–4×); it changes the clip's timeline length, and later titles/captions ripple to stay in sync.
- set_transition joins a clip into the next one (0–2s, six styles) — read the transitions-and-fades skill before styling cuts. Splitting or deleting clears the affected transition.
- split_at cuts the clip under that time into two clips at the exact frame. With a soundtrack clip selected it splits that instead.
- delete_item removes items; the video track closes the gap automatically. The user can multi-select (⌘/⇧-click) and delete several at once.
- detach_audio lifts a video clip's sound to the soundtrack track (and mutes the clip) so audio can be cut independently of video.
- freeze_frame grabs one frame (default: the playhead — what the user currently sees) as a still clip and inserts it, by default at index 0 as a cover/hook frame ("make this the first frame"). The still is baked at the project's current aspect with the clip's framing applied; if the user later switches aspect they should capture a fresh one.
- set_framing: per-clip Fit (letterbox) vs Fill (crop to cover the project frame). In Fill, panX/panY position the crop window; the user can also drag the video directly in the preview. The control lives in the Inspector under "Framing" when a video clip is selected. Landscape footage usually wants fill + a pan that keeps the subject.
- The user can copy/paste any selected segment (video, audio, title) with ⌘C/⌘V; pastes land at the playhead.
- Zoom: set_view pxPerSec (12..800) or fit. The timeline panel height: set_view timelineH (170..600).`,

  "transitions-and-fades": `# Transitions & fades
Three fade-like features exist; route the ask to the right one:
- set_transition: a styled join between one video clip and the next.
- set_project_fade: the whole video fades in from black at the start and/or out to black at the end — picture and full mix (titles, captions, soundtrack). Survives clip reordering. For "fade in the video", "fade to black at the end", use this. Shown as "Fade in"/"Fade out" on the first/last clip's Inspector panel.
- update_audio fadeIn/fadeOut: audio-only ramps on one soundtrack clip ("fade the music out").

set_transition(clipId, seconds, style): clipId is the leading clip of the joint; 0 clears, max 2s. Styles:
- crossfade (default): A blends into B. Overlaps the clips, so the cut shortens by the duration.
- crosszoom: the blend plus a zoom punch — A pushes in (1→1.18×) while B settles back. Also overlaps.
- zoomin: A's tail zooms in across a hard cut (duration unchanged). zoomout: B's head settles from zoomed to normal.
- fadeout: A's tail fades to black (its audio too), then a hard cut. fadein: B's head fades up from black.
Picking for a vibe: "smooth/dissolve" → crossfade; "punchy/energetic/zoom" → crosszoom; "dramatic pause/scene change" → fadeout 0.5–0.8s; between clips 0.4–0.8s reads well, 1s+ is slow and cuts total duration for cross styles.
UI: select a clip → Inspector "Transition" (style) + "Length"; a blue badge marks each styled joint on the timeline. Preview and export render the same look.`,

  "titles": `# Titles (text overlays)
Each overlay: text, start/end (seconds visible), x/y center (fractions 0..1 of the project frame), size (frame px; the design short side is 1080), font (sf=SF Pro, serif=New York, rounded, mono, impact), weight (400/700), color (any CSS color), shadow (bool), plate (translucent dark plate behind the text).
Inspector shows these when a title is selected. The color row has fixed swatches, a custom picker, and the last 3 custom colors.
Good TikTok titles: short punchy lines, high contrast (white/yellow + shadow or plate), size 72–110, keep inside the middle 80% of the frame (x 0.1..0.9, y 0.1..0.9), avoid the caption band (y≈0.8) when subtitles are on.
Titles burn into the export exactly as previewed.`,

  "audio-and-subtitles": `# Audio, voiceover & subtitles
Soundtrack clips: volume 0..1.5, fadeIn/fadeOut seconds (max half the clip), start = timeline position, in/out = trim inside the source. Fades render with ffmpeg afade on export.
Ducking: a soundtrack clip's \`duck\` (0..1, via update_audio) lowers ALL other audio — video-clip sound and other music — to that gain while the clip plays; 1 clears it. Voiceovers set this so narration sits over quieter music. It applies in both the preview and the export.
Voiceover (Donkey's hosted speech model — signed in, spends credits, like image/video generation):
- voiceover_generate(script, voice?, direction?, duck?, start?): synthesizes the script and drops it on the soundtrack at the playhead (or start). Defaults to a 0.4 duck so it sits over other audio. Voices are Gemini's prebuilt set — list_voices returns them (id + one-word character like Warm, Upbeat, Gravelly); omit voice for a good default. \`direction\` steers delivery in natural language ("Say warmly, like an old friend"); the script itself can carry inline tags like [whispers], [excited], [laughs].
- read_subtitles_aloud(voice?, direction?, duck?): speaks the existing subtitle cues, each line at its own cue time — captions become narration. Needs cues first.
Subtitles: subtitles_generate transcribes the cut's audio on-device (Apple speech, macOS 26); cues are caption-sized (≈38 chars). subtitles_from_visuals is the fallback for a cut with NO speech — it watches sampled frames (via the user's Claude login) and writes timed narration captions of what's on screen. So: speech present → subtitles_generate; silent/music-only footage the user wants captioned → subtitles_from_visuals. Never fabricate a spoken transcript.
captions_generate rewrites existing cues into punchy social captions (emoji, curiosity-hook opener) in a style (clean/hook/punchy), keeping timings — use it when the ask is social/TikTok captions rather than a plain transcript.
Editing: update_cue (text or retime), delete_cue, merge_cue. In the panel, Return splits a caption at the cursor onto real word timings; hand-edited text drops its word timings.
subtitles_set_view: showOnVideo (preview + export burn-in), showOnTimeline (amber cue track).
Caption look: the Subtitles panel offers 10 visual presets (clean, hook, punchy, minimal, editorial, typewriter, block, highlight, bubble, neon), a per-word karaoke highlight with accent overrides, and the caption block drags to a new spot in the preview. No tool sets the look — direct the user to the panel. captions_generate's clean/hook/punchy choice shapes the caption text it writes; the visual preset is separate.`,

  "ai-generation": `# AI image & video generation
Cut can generate media the user doesn't have footage for, through Donkey's hosted models (generation — images, video, voiceovers — is the signed-in, credit-spending feature; everything else is local and free). Both land the result in the project's Media and, by default, drop it on the timeline.
- generate_image(prompt, add_to_timeline?, index?): a hosted image model renders the prompt; the image is baked into an 8s still clip framed for the project aspect. Great for a cover/hook frame (index 0), a background, or a b-roll still. Slower footage the user lacks → generate it rather than asking them to find it.
- generate_video(prompt, tier?, duration_seconds?, add_to_timeline?, index?): a hosted Veo model renders a short clip (4–8s) with audio, framed for the project aspect. tier "fast" (default) is quicker/cheaper, "high" is best quality. This takes a minute or two, so the tool returns right away and the clip appears in Media (and on the timeline by default) when it finishes — tell the user it's rendering. Don't call it again for the same shot while one is in flight.
Both compose for editor_state project.aspect, so set the aspect first if the user wants a different frame. If either fails with a sign-in or credits message, relay that plainly — generation needs the user signed in to Donkey with credits; it is not a local fallback. Write vivid, specific prompts (subject, style, lighting, motion); the user's request is usually shorthand, so flesh it out.`,

  "publish-and-export": `# Publish & export
Publish tab fields (set_publish): caption (TikTok limit 4,000 chars INCLUDING tags/emoji; hook in the first line), tags (3–5 focused tags recommended; stored space-separated, rendered as #tags), soundTitle (TikTok lets you rename the sound once after posting), handle (shown as @handle in platform previews).
Export (open_export): presets Original (matches the sharpest source clip along the aspect, 1080p floor, 4K cap), Best 1080p CRF19, Quick share 1080p, Draft 720p — H.264 + AAC, 30fps, rendered at the project aspect (9:16 or 16:9), titles and subtitles burned in. Files land in the project's exports/ folder and appear in the Media tab's Exports section, where each can be previewed plain or in TikTok/Instagram/YouTube chrome with the publish metadata rendered in place, revealed in Finder, or deleted.`,
};

/** System prompt shared by all providers. */
export function systemPrompt(): string {
  return `You are Cut's editing copilot, embedded in a local TikTok video editor. You see the user's project through the <editor_state> snapshot attached to each message and through your tools, and you edit it by calling tools — the user watches changes land live.

Rules:
- Act directly with tools; don't describe steps the user should click through unless they ask how.
- Use ids exactly as given in the state; if unsure or state may have changed, call get_state first.
- When the user says "this" (this clip, this text), they mean the current selection.
- Keep replies short and concrete — one or two sentences about what you did. No headings, no fluff.
- All edits are undoable (unlimited undo), so prefer doing over asking. Only ask when the request is genuinely ambiguous.
- Times are seconds. The frame is the project's aspect: 1080×1920 (9:16) or 1920×1080 (16:9) — see project.aspect in editor_state.
- Read list_skills / read_skill before working in an area you're unsure about — they document every setting.
- Don't transcribe a video with no speech. If the user wants captions on silent footage, use subtitles_from_visuals (it narrates what's on screen). Never invent a spoken transcript.
- Voiceovers duck other audio by default so they stay audible. Steer a voiceover's delivery with \`direction\` and inline tags like [whispers] rather than rewriting the script.
- generate_image / generate_video / voiceover_generate / read_subtitles_aloud make media through hosted models (spends the user's Donkey credits, needs sign-in). Default to adding the result to the timeline; write a rich, specific prompt from their shorthand. generate_video takes a minute or two.
- capture_frame shows you the actual rendered frame when visual judgment matters.`;
}

export const AI_SKILL_INDEX = Object.keys(AI_SKILLS);

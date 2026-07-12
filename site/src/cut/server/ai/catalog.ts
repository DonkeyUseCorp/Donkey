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
      "Capture the composited video frame the preview shows at the playhead as an image. Titles and captions are drawn over the canvas in the UI, so they don't appear here — this checks the footage, not the text.",
    inputSchema: obj({}),
  },
  {
    name: "watch_video",
    description:
      "Watch a video source with your own eyes: samples its frames at scene changes plus a steady floor into timestamped contact-sheet images, and returns the detected scene-change times (natural cut candidates). Pass clip_id to watch a timeline clip's source (the result includes that clip's source↔timeline time math) or asset_id for any project video or image. The stamp burned into each cell is SOURCE seconds — what trim_clip's in/out use — not timeline seconds. Coverage is capped per call: survey the whole range first, then call again with a narrow from/to and a small interval_seconds where the cut needs care; the result says where coverage stopped. Read the watching-and-cutting skill before editing footage by content.",
    inputSchema: obj({
      clip_id: str("Video clip id, track 0 or overlay (defaults from/to to its trimmed in/out)"),
      asset_id: str("Project asset id (video or image) — watch the source itself"),
      from: num("Source start s (default: the clip's in, else 0)"),
      to: num("Source end s (default: the clip's out, else the source's end; spans at most 600s per call)"),
      interval_seconds: num("Target seconds between sampled frames, 0.5–30 (default spreads ~32 frames across the range)"),
    }),
  },
  {
    name: "detect_silence",
    description:
      "Find silent stretches in a source's audio — dead air, long pauses, gaps between takes. Returns [{start,end,duration}] in SOURCE seconds, plus each one's timeline times when clip_id is passed. Cheap and image-free; pair it with the transcript's cue timings to find filler, then cut with split_at / trim_clip / delete_item.",
    inputSchema: obj({
      clip_id: str("Clip id — video, overlay, or soundtrack; scopes to its trimmed range and maps results to timeline seconds"),
      asset_id: str("Project asset id (video or audio)"),
      from: num("Source start s (default: the clip's in, else 0)"),
      to: num("Source end s (default: the clip's out, else the source's end)"),
      threshold_db: num("Loudness below this counts as silence, dBFS (default -30)"),
      min_silence: num("Shortest silent stretch to report, seconds (default 0.35)"),
    }),
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
      "Select a video clip (on any track), soundtrack clip, or title (or clear the selection). Selection drives the inspector panel.",
    inputSchema: obj({
      kind: { type: "string", enum: ["clip", "audio", "text", "none"], description: "What to select — 'clip' is any video clip, whatever track" },
      id: str("The item id (omit for kind=none)"),
    }, ["kind"]),
  },
  {
    name: "split_at",
    description:
      "Split the video (or a selected soundtrack/overlay clip) at a time, like pressing S. Omit t to split at the playhead.",
    inputSchema: obj({ t: num("Timeline seconds to cut at (optional)") }),
  },
  {
    name: "move_clip",
    description:
      "Reorder a track-0 video clip to a new index: it lifts out (its old spot becomes a gap) and clips from the landing index shift right to make room — nothing else moves, so sound and titles stay synced. To move one clip in time, use place_clip.",
    inputSchema: obj({ clipId: str("Video clip id"), toIndex: num("Target index, 0-based") }, ["clipId", "toIndex"]),
  },
  {
    name: "place_clip",
    description:
      "Move a track-0 video clip to a timeline start time (seconds). The track is free-positioned: gaps are allowed and play black. If another clip occupies that spot, the clip slides right to the next free one.",
    inputSchema: obj({ clipId: str("Video clip id"), start: num("Target timeline start s") }, ["clipId", "start"]),
  },
  {
    name: "add_clip",
    description:
      "Put a project asset on the timeline, the same way the user dragging it in would: a video or image lands on video track 0 (at `start`, inserted at `index`, or appended at the end; a taken spot slides it right), audio lands on the soundtrack (at `start`, default the playhead). Asset ids come from `media` in editor_state — imports, attachments, and chat media alike. Call it only when the user asked for the media in the cut (\"add my beach photo\", \"stitch these into a movie\"); otherwise media stays on its card or panel for them to drag.",
    inputSchema: obj({
      asset_id: str("Project asset id from `media` in editor_state"),
      start: num("Timeline start s"),
      index: num("Insert position on video track 0 (video/image only; 0 = first)"),
    }, ["asset_id"]),
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
    description:
      "Delete a video clip (any track), soundtrack clip, or title by id. Every track is free-positioned, so deleting leaves a gap; place_clip can slide a neighbor into it if the cut should stay tight.",
    inputSchema: obj({
      kind: { type: "string", enum: ["clip", "audio", "text"], description: "Item kind — 'clip' is any video clip, whatever track" },
      id: str("Item id"),
    }, ["kind", "id"]),
  },
  {
    name: "add_overlay_video",
    description:
      "Put a project video or image asset on an overlay video track, composited with track 0: track 1+ sits above it (the topmost full-frame clip covers everything below), negative tracks sit behind it. Pick a layout to share the frame — halves for a split screen, pip for picture-in-picture. Asset ids come from `media` in the editor state.",
    inputSchema: obj({
      asset_id: str("Project asset id (video or image)"),
      start: num("Timeline start s (default: the playhead)"),
      track: num("Video track, non-zero; 1 = first layer above track 0, -1 = behind it (default 1)"),
      layout: {
        type: "string",
        enum: ["full", "top", "bottom", "left", "right", "pip"],
        description: "Frame region (default full = covers the frame)",
      },
    }, ["asset_id"]),
  },
  {
    name: "update_overlay_video",
    description:
      "Update an overlay video clip: move it (start, track), trim (in/out), mute, hide, change its frame region (layout preset, or a custom region rect in frame fractions), fit, or speed.",
    inputSchema: obj({
      id: str("Overlay video clip id"),
      start: num("Timeline start s"),
      in: num("Source in s"),
      out: num("Source out s"),
      track: num("Video track, non-zero; positive above track 0, negative behind"),
      muted: bool("Mute the clip's own audio"),
      hidden: bool("Hide the layer without deleting it"),
      layout: {
        type: "string",
        enum: ["full", "top", "bottom", "left", "right", "pip"],
        description: "Frame region preset",
      },
      region: obj({
        x: num("Left edge 0..1"),
        y: num("Top edge 0..1"),
        w: num("Width 0..1"),
        h: num("Height 0..1"),
      }, ["x", "y", "w", "h"]),
      fit: { type: "string", enum: ["fit", "fill"], description: "How the video meets its region" },
      speed: num("Playback rate 0.25–4"),
    }, ["id"]),
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
      "Generate an AI image from a text prompt (Donkey's hosted image model). Use for B-roll, cover frames, or backgrounds the user doesn't have footage for; when the user asks you to write or improve the prompt itself, put it in chat and wait for them to ask for the image. reference_asset_ids attaches project images/video frames the render should draw from (the user's attached references, a clip to restyle) — the prompt is recomposed around them. Returns when the image has landed. The image previews as a card in this chat, where the user can expand it, drag it onto the timeline, or file it into Media or the Library from its \"…\" menu; pass add_to_timeline:true (or an index) only when they asked for it in the cut. Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      prompt: str("What to depict — be specific about subject, style, and lighting"),
      aspect: { type: "string", enum: ["16:9", "9:16", "1:1"], description: "Image shape (default: the project aspect)" },
      resolution: { type: "string", enum: ["1K", "2K", "4K"], description: "Output detail (default 1K)" },
      reference_asset_ids: {
        type: "array",
        items: { type: "string" },
        description: "Project asset ids (images or videos) to use as visual references",
      },
      add_to_timeline: bool("Insert the still on the video track (default false — it stays on its chat card until the user asks)"),
      index: num("Insert position on the video track (passing it implies add_to_timeline; 0 = first/cover)"),
    }, ["prompt"]),
  },
  {
    name: "generate_video",
    description:
      "Generate an AI video clip from a text prompt (Donkey's hosted Veo model). Use for B-roll or shots the user doesn't have footage for; when the user asks you to write or improve the prompt itself, put it in chat and wait for them to ask for the video. reference_asset_id seeds the render with one project image or video frame (it becomes the opening frame when the subject is used as-is). This renders remotely and takes a minute or two, so the tool RETURNS IMMEDIATELY — the clip previews as a live card in this chat (and in the Video panel's renders) when it finishes. Tell the user it's rendering. Pass add_to_timeline:true (or an index) only when they asked for it in the cut; otherwise the user drags it in from the card. Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      prompt: str("The shot to generate — describe motion, subject, and mood"),
      tier: { type: "string", enum: ["fast", "high"], description: "fast = quicker/cheaper (default), high = best quality" },
      duration_seconds: num("Clip length 4–8 seconds (default 8)"),
      aspect: { type: "string", enum: ["16:9", "9:16"], description: "Clip shape (default: the project aspect)" },
      resolution: { type: "string", enum: ["720p", "1080p"], description: "Output detail (default 720p)" },
      reference_asset_id: str("One project asset id (image or video) to seed the render"),
      add_to_timeline: bool("Insert the clip on the video track when it lands (default false — it stays on its chat card until the user asks)"),
      index: num("Insert position on the video track (passing it implies add_to_timeline)"),
    }, ["prompt"]),
  },
  {
    name: "generate_character_video",
    description:
      "Generate a UGC-style selfie clip of a stock talking character speaking a line you write (Donkey's hosted Veo model). Pick a character id from stock_search kind:\"character\" — each has a persona and look; the same person then delivers the line to camera. Like generate_video this RETURNS IMMEDIATELY and the clip previews in this chat (and the Video panel's renders) a minute or two later; add_to_timeline:true places it when it lands. Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      character_id: str("Talking-character id from stock_search"),
      line: str("What the character says, spoken to camera"),
      tier: { type: "string", enum: ["fast", "high"], description: "fast = quicker/cheaper (default), high = best quality" },
      duration_seconds: num("Clip length 4–8 seconds (default 8)"),
      add_to_timeline: bool("Insert the clip on the video track when it lands (default false — it stays on its chat card until the user asks)"),
      index: num("Insert position on the video track (passing it implies add_to_timeline)"),
    }, ["character_id", "line"]),
  },
  {
    name: "stock_search",
    description:
      "Search Cut's bundled stock catalogs: footage clips and stock images across Business/Nature/Travel/City/Technology/Anime/Animal/Food categories, plus talking characters (personas for generate_character_video). Stock is local and free — check it before spending generation credits when existing media could serve. Add a match to the project with stock_add.",
    inputSchema: obj({
      query: str("Words to match against prompts, categories, and tags (omit to browse)"),
      kind: { type: "string", enum: ["video", "image", "character"], description: "Limit to one catalog (default: all)" },
    }),
  },
  {
    name: "stock_add",
    description:
      "Import a stock video or image (by stock_search id) into the project. It previews as a card in this chat; pass add_to_timeline:true (or a `start`) to also drop it on the video track when the user asked for it in the cut. Free — the media ships with Cut.",
    inputSchema: obj({
      id: str("Stock item id from stock_search"),
      add_to_timeline: bool("Place it on video track 0 (default false — it stays on its chat card until the user asks)"),
      start: num("Timeline start s (passing it implies add_to_timeline; default when placed: appended at the end)"),
    }, ["id"]),
  },
  {
    name: "subtitles_generate",
    description:
      "Transcribe the cut on-device (Apple speech) and create subtitle captions on a subtitle track (the active one unless `track` says otherwise; other tracks keep their captions). Runs in the background; returns when finished. If no speech is found, no subtitles are added.",
    inputSchema: obj({
      locale: str("Speech language as BCP-47 like en-US (default: the track's language)"),
      track: num("Subtitle track to write, 0-based (default: the active track)"),
    }),
  },
  {
    name: "captions_generate",
    description:
      "Transcribe (if needed) then rewrite one subtitle track's captions into punchy social-video captions — short lines that fit inside the video frame (they may wrap onto two lines but never overflow), a few emoji, a curiosity-hook opener. style: clean | hook | punchy (default hook). Cue timings are preserved.",
    inputSchema: obj({
      style: str("Caption style: clean, hook, or punchy"),
      track: num("Subtitle track to rewrite, 0-based (default: the active track)"),
    }),
  },
  {
    name: "subtitles_from_visuals",
    description:
      "Caption a cut that has NO usable speech by watching sampled frames and writing timed narration captions (uses the user's Claude login to look at the frames). Use this instead of subtitles_generate when the video is silent b-roll, music-only, or otherwise has nothing to transcribe. Runs in the background; returns when finished.",
    inputSchema: obj({
      locale: str("Caption language as BCP-47 like en-US (default: the track's language)"),
      track: num("Subtitle track to write, 0-based (default: the active track)"),
    }),
  },
  {
    name: "subtitles_add_track",
    description:
      "Add a subtitle track (up to 3, one language each — e.g. English on track 0, Korean on track 1; each shows as its own caption line, draggable to its own spot). The new track becomes active and starts empty: fill it with subtitles_translate_track, or subtitles_generate in its language.",
    inputSchema: obj({ language: str("The track's language as BCP-47, e.g. ko-KR (optional)") }),
  },
  {
    name: "subtitles_remove_track",
    description: "Remove a subtitle track and its captions; higher tracks shift down.",
    inputSchema: obj({ track: num("Track to remove, 0-based") }, ["track"]),
  },
  {
    name: "subtitles_translate_track",
    description:
      "Translate existing captions into another language on their own subtitle track — the way to answer \"add Korean subtitles\". Reuses the track already set to that language or adds one (max 3), then translates the source track's cues one-to-one, timings kept. The captions must exist first (subtitles_generate).",
    inputSchema: obj({
      language: str("Target language as BCP-47, e.g. ko-KR"),
      from_track: num("Source track, 0-based (default: the first track with captions)"),
    }, ["language"]),
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
      "Generate a spoken AI voiceover from a script (Donkey's hosted speech model). The audio previews as a playable card in this chat; pass add_to_timeline:true (or a `start`) to also drop it on the soundtrack when the user asked for it in the cut ('add a voiceover', 'narrate this'). When the user asks you to write or rework the script itself, put the text in chat and wait for them to ask for the voiceover. Pick a `voice` id from list_voices, or omit for a good default. `direction` steers delivery in natural language and can ask for another language — 'say it in Spanish' translates the script before synthesis; the script itself may carry inline tags like [whispers] or [excited]. `duck` lowers all other audio to that gain while the voice plays (0..1; ~0.3–0.5 is typical, 1 = don't duck). Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      script: str("What the voice should say"),
      voice: str("Voice id from list_voices (optional; a sensible default is chosen)"),
      direction: str("Delivery instruction, e.g. 'Say warmly, like an old friend'; may include a language ask, which translates the script (optional)"),
      language: str("Pronunciation language as BCP-47, e.g. es-US, ja-JP (optional; default auto-detects — this reads the script as written, it does not translate)"),
      duck: num("Lower other audio to this gain while the voice plays, 0..1 (default 0.4; 1 = no ducking)"),
      add_to_timeline: bool("Place it on the soundtrack (default false — it stays on its chat card until the user asks)"),
      start: num("Timeline start in seconds (passing it implies add_to_timeline; default when placed: the playhead)"),
    }, ["script"]),
  },
  {
    name: "read_subtitles_aloud",
    description:
      "Speak one subtitle track's cues as an AI voiceover (Donkey's hosted speech model) — each line placed at its own cue time — and add it to the soundtrack. Turns captions into narration. Requires subtitles to exist first (generate them if needed). `duck` lowers other audio under the voice (0..1). Needs the user signed in to Donkey (spends their credits).",
    inputSchema: obj({
      voice: str("Voice id from list_voices (optional)"),
      direction: str("Delivery instruction, e.g. 'Narrate briskly, documentary style'; may include a language ask, which translates the lines (optional)"),
      language: str("Pronunciation language as BCP-47, e.g. es-US, ja-JP (optional; default auto-detects — reads cues as written; for another language use a translated subtitle track)"),
      duck: num("Lower other audio to this gain while the voice plays, 0..1 (default 0.4)"),
      track: num("Subtitle track to read, 0-based (default: the active track)"),
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
      "Open the export dialog so the user can render the cut (presets from Original quality down to Draft 720p). Exporting itself stays a user action.",
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
    description:
      "Merge a subtitle cue into the previous cue on its own track (joins their text and timing). Not valid for a track's first cue.",
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
- Left icon rail tabs: Media (user-imported files + Exports list), Library (shared reusable assets), Video (stock clip browser — footage + talking characters — beside the AI video generator), Image (stock images beside the AI image generator), Audio (AI voiceover + audio files), Text (title presets), Subtitles (transcript editor), Publish (caption/tags/sound metadata). Camera/mic recording lives in the top bar next to the aspect picker.
- Media shows only what the user imported. Everything Cut makes carries an origin tag (generated, voiceover, recording, stock, freeze, chat — see \`media\` in editor_state) and lives where it was created — media you make previews on a card in this chat, panel renders sit in their job lists; a "…" menu on each files it into Media or the Library, and every card drags onto the timeline. Deleting a chat thread deletes the chat media the user never placed or filed away.
- Center: the video preview canvas (composited at the project's frame size) with draggable text overlays and subtitle captions.
- Right: the Inspector — its content follows the selection (video clip, overlay video, soundtrack clip, title, or cue).
- Bottom: the timeline (resizable by dragging its top border). Rows top-to-bottom: the video tracks in z-order (positive tracks, then track 0, then negative tracks behind it), soundtrack lanes (green), titles (purple), subtitle tracks (amber, when enabled). Every track is free-positioned in time.
Everything autosaves to the project folder. Undo/redo is unlimited (⌘Z / ⇧⌘Z).
Times are in seconds on the shared timeline. The playhead is currentTime; a skimmer previews under the mouse without moving the playhead.`,

  "timeline-editing": `# Timeline editing
- Every track is free-positioned: items carry a start time, gaps are allowed, and a track-0 gap plays black (and silence). Deleting leaves a gap. videoTrack entries in editor_state report gapBefore where one exists.
- Two ways to move a track-0 clip: place_clip sets its start (respects gaps, slides right if the spot is taken); move_clip reorders by index, opening a slot at the landing point — clips after it shift right, every other gap survives. Index-based inserts (freeze_frame, generated clips) open a slot the same way.
- add_clip puts a project asset on the timeline the way a drag does: video/image onto track 0 (a \`start\`, an \`index\` insert, or appended at the end), audio onto the soundtrack.
- Overlay video: a video/image asset can sit on a track above track 0 (track 1, 2… — topmost wins) or behind it (track -1…). A full-frame overlay covers everything below it; give it a layout to share the frame — top/bottom/left/right halves for a split screen, pip for a floating corner box, or a custom region rect. add_overlay_video creates one from a media asset; update_overlay_video moves/trims/regions/mutes/hides it. The user makes them by dragging media above/below track 0; they drag the region in the preview.
- A clip's timeline length is (out-in)/speed; total duration runs to the last clip's end, gaps included, minus cross-style transition overlaps.
- trim_clip changes in/out inside the source media. in >= 0, out <= source duration, out-in >= 0.1.
- set_speed sets a clip's playback rate (0.25–4×); it changes the clip's timeline length, and later titles/captions ripple to stay in sync.
- set_transition joins a clip into the next one (0–2s, six styles) — read the transitions-and-fades skill before styling cuts. Splitting or deleting clears the affected transition.
- split_at cuts the track-0 clip under that time into two clips at the exact frame. With a soundtrack or overlay clip selected it splits that instead.
- The user can multi-select (⌘/⇧-click) and delete several items at once; a hover chip on each video clip toggles its own audio.
- detach_audio lifts a video clip's sound to the soundtrack track (and mutes the clip) so audio can be cut independently of video.
- freeze_frame grabs one frame (default: the playhead — what the user currently sees) as a still clip and inserts it, by default at index 0 as a cover/hook frame ("make this the first frame"). The still is baked at the project's current aspect with the clip's framing applied; if the user later switches aspect they should capture a fresh one.
- set_framing: per-clip Fit (letterbox) vs Fill (crop to cover the project frame). In Fill, panX/panY position the crop window; the user can also drag the video directly in the preview. The control lives in the Inspector under "Framing" when a video clip is selected. Landscape footage usually wants fill + a pan that keeps the subject.
- The user can copy/paste any selected segment (video, overlay video, audio, title) with ⌘C/⌘V; pastes aim for the playhead and slide right to free space.
- Zoom: set_view pxPerSec (12..800) or fit. The timeline panel height: set_view timelineH (170..600).`,

  "watching-and-cutting": `# Watching footage & cutting by content
When a request depends on what the footage actually contains — "cut the dead air", "clip the best moment", "remove the boring part", "split where the scene changes" — watch it first. Never guess at content you haven't seen.

Your eyes and ears:
- watch_video(clip_id | asset_id, from?, to?, interval_seconds?): samples the SOURCE at scene changes plus a steady floor and returns timestamped contact sheets — cells read left→right, top→bottom, and each burned stamp is source seconds — plus sceneChanges, the natural cut candidates. Coverage is capped per call: survey the whole range at the default interval first, then zoom into the moments that matter with a narrow from/to and interval_seconds 0.5–1. When truncated, continue from coveredTo.
- detect_silence(clip_id | asset_id, threshold_db?, min_silence?): silent stretches in source seconds; with clip_id each also carries its timeline times.
- capture_frame: one composited frame at the playhead — for checking the final look, not for surveying footage.

The flow for "edit this for me":
1. get_state — every clip, its trim (in/out), speed, gaps, and the other tracks.
2. Speech? subtitles_generate first — cue timings are timeline seconds and say what is said when.
3. watch_video each distinct source (or the ranges in question); note scene changes and what happens where.
4. Trimming dead air: detect_silence, then cross-check cue gaps so a cut never clips a word.
5. Execute: split_at (timeline s) to divide, delete_item to drop a segment, trim_clip (source s) to tighten edges, place_clip/move_clip to close gaps or reorder, set_speed to compress slow stretches.
6. Verify: seek to each new cut; capture_frame when the change is visual.

Time math (get this right):
- watch_video, detect_silence, and trim_clip speak SOURCE seconds; split_at and place_clip speak TIMELINE seconds.
- timeline_t = clip.start + (source_t − clip.in) / clip.speed, valid while source_t is inside [in, out]. Each watch result's clip block carries this formula with the real numbers filled in.
- The same source can appear in several clips — map per clip.

Cutting dead air well: leave ~0.2s of breathing room around speech; prefer split_at + delete_item, then place_clip to close the gap (a beat of black may be wanted — ask the cut, not the tool); trim_clip only tightens a clip's edges.`,

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
Soundtrack clips: volume 0..1.5, fadeIn/fadeOut seconds (max half the clip), start = timeline position, in/out = trim inside the source; clips can spread across several soundtrack lanes (the \`lane\` field), new sounds slide to free space in their lane. Fades render with ffmpeg afade on export.
Ducking: a soundtrack clip's \`duck\` (0..1, via update_audio) lowers ALL other audio — video-clip sound and other music — to that gain while the clip plays; 1 clears it. Voiceovers set this so narration sits over quieter music. It applies in both the preview and the export.
Voiceover (Donkey's hosted speech model — signed in, spends credits, like image/video generation):
- voiceover_generate(script, voice?, direction?, duck?, add_to_timeline?, start?, language?): synthesizes the script into a playable chat card; add_to_timeline:true (or a start) also drops it on the soundtrack at the playhead (or start) when the user asked for it in the cut. Defaults to a 0.4 duck when placed so it sits over other audio. Voices are Gemini's prebuilt set — list_voices returns them (id + one-word character like Warm, Upbeat, Gravelly); omit voice for a good default. \`direction\` steers delivery in natural language ("Say warmly, like an old friend") and may ask for another language — "say it in Spanish" translates the script before synthesis; the script itself can carry inline tags like [whispers], [excited], [laughs]. \`language\` only pins pronunciation of the text as written.
- read_subtitles_aloud(voice?, direction?, duck?, track?): speaks one subtitle track's cues, each line at its own cue time — captions become narration. Needs cues first. The Inspector offers the same per-clip: "Generate audio for clip" transcribes just that clip when it has no cues yet, then voices it.
Subtitle tracks: a project carries up to 3, one language each (editor_state subtitles.tracks; each cue's \`track\`). Each track shows its own caption line, dragged to its own spot; all share one visual style. The panel and generation write to the ACTIVE track — the track tool param switches it. subtitles_add_track / subtitles_remove_track manage them; subtitles_translate_track("ko-KR") is the whole "add Korean subtitles" flow when captions exist (it adds/reuses the track and translates cue-for-cue).
Generating: subtitles_generate transcribes the cut's audio on-device (Apple speech, macOS 26) onto the target track; cues are caption-sized (≈38 chars). subtitles_from_visuals is the fallback for a cut with NO speech — it watches sampled frames (via the user's Claude login) and writes timed narration captions of what's on screen. So: speech present → subtitles_generate; silent/music-only footage the user wants captioned → subtitles_from_visuals. Never fabricate a spoken transcript.
captions_generate rewrites a track's cues into punchy social captions (emoji, curiosity-hook opener) in a style (clean/hook/punchy), keeping timings — use it when the ask is social/TikTok captions rather than a plain transcript.
Editing: update_cue (text or retime), delete_cue, merge_cue (joins into the previous cue on the same track). In the panel, Return splits a caption at the cursor onto real word timings; hand-edited text drops its word timings.
subtitles_set_view: showOnVideo (preview + export burn-in), showOnTimeline (amber cue rows).
Caption look: the Subtitles panel offers 10 visual presets (clean, hook, punchy, minimal, editorial, typewriter, block, highlight, bubble, neon), a per-word karaoke highlight with accent overrides, and each track's caption drags to a new spot in the preview. No tool sets the look — direct the user to the panel. captions_generate's clean/hook/punchy choice shapes the caption text it writes; the visual preset is separate.`,

  "ai-generation": `# Stock media & AI generation
Two ways to get footage the user doesn't have: bundled stock (local, free) and hosted generation (signed in, spends credits). Prefer stock when it genuinely fits; generate when the shot needs to be specific.
Stock: stock_search browses the bundled catalogs — footage clips and images in 8 categories plus ~20 UGC talking characters — matching prompts, categories, and tags. stock_add imports an item into the project as a chat card; add_to_timeline:true (or a start) also drops it on the timeline when the user asked. In the UI these live in the Video and Image tabs beside the generators; clicking a stock tile seeds the generate panel with its prompt.
Generation:
- generate_image(prompt, aspect?, resolution?, reference_asset_ids?, add_to_timeline?, index?): the hosted image model renders the prompt at 16:9, 9:16, or 1:1 (default: project aspect) and 1K/2K/4K. The still previews in the chat; placed (add_to_timeline:true or an index) it rides video track 0 as a still clip (8s default, stretchable). Great for a cover/hook frame (index 0), a background, or a b-roll still.
- generate_video(prompt, tier?, duration_seconds?, aspect?, resolution?, reference_asset_id?, add_to_timeline?, index?): a hosted Veo model renders a 4–8s clip with audio. tier "fast" (default) is quicker/cheaper, "high" is best quality. This takes a minute or two, so the tool returns right away and the clip previews in the chat and the Video panel's renders when it finishes (on the timeline only when asked) — tell the user it's rendering. Don't call it again for the same shot while one is in flight.
- generate_character_video(character_id, line, …): a stock talking character delivers a line to camera, same async render as generate_video. Characters come from stock_search kind:"character" — each has a persona; you write the line (chat deliverable rules apply: asked for "a script", write it in chat first).
References: users attach images/clips to their message or the generate panels; project asset ids (see \`media\` in editor_state, including attachments — OS drops become project assets) pass through reference_asset_ids / reference_asset_id. A model recomposes the prompt around them: for video at most one image survives as the literal opening frame; for images any number can be drawn from. When the user says "use this clip/image", pass the reference — don't just describe it in the prompt.
If generation fails with a sign-in or credits message, relay that plainly — it needs the user signed in to Donkey with credits; it is not a local fallback. Write vivid, specific prompts (subject, style, lighting, motion); the user's request is usually shorthand, so flesh it out.`,

  "publish-and-export": `# Publish & export
Publish tab fields (set_publish): caption (TikTok limit 4,000 chars INCLUDING tags/emoji; hook in the first line), tags (3–5 focused tags recommended; stored space-separated, rendered as #tags), soundTitle (TikTok lets you rename the sound once after posting), handle (shown as @handle in platform previews).
Export (open_export): presets Original (matches the sharpest source clip along the aspect, 1080p floor, 4K cap), Best 1080p CRF19, Quick share 1080p, Draft 720p — H.264 + AAC, 30fps, rendered at the project aspect (9:16 or 16:9), titles and subtitles burned in. Files land in the project's exports/ folder and appear in the Media tab's Exports section, where each can be previewed plain or in TikTok/Instagram/YouTube chrome with the publish metadata rendered in place, revealed in Finder, or deleted.`,
};

/** System prompt shared by all providers. */
export function systemPrompt(): string {
  return `You are the AI editor built into a video editor. Your voice is kind with a light sense of humor — warm first, one small joke at most, and always clear about what you did. You see the user's project through the <editor_state> snapshot attached to each message and through your tools, and you edit it by calling tools — the user watches changes land live.

Rules:
- First decide what the user wants handed back: an edit to the project, or words in chat. "Give me / write me a prompt, script, caption, ideas, a translation" asks for the text itself — write it in chat and leave the project untouched, even though a tool could act on it; they'll say "do it" or "add it" when they want it applied (and a follow-up like "in Korean" or "shorter" revises the text, keeping the same deliverable). When they do ask for a change to the project, act directly with tools; don't describe steps they should click through unless they ask how.
- Use ids exactly as given in the state; if unsure or state may have changed, call get_state first.
- When the user says "this" (this clip, this text), they mean the current selection.
- Keep replies short and concrete — one or two sentences about what you did, in that warm, lightly funny voice. You have no name and never name the app; greet with a short "How can I help?" / "What would you like to do?". No headings, no fluff.
- Edits are undoable (unlimited undo), so prefer doing over asking; only ask when the request is genuinely ambiguous. Generation is different: undo removes the clip but the credits stay spent, so be certain the user asked for the media before calling a generation tool.
- Times are seconds. The frame is the project's aspect: 1080×1920 (9:16) or 1920×1080 (16:9) — see project.aspect in editor_state.
- Read list_skills / read_skill before working in an area you're unsure about — they document every setting.
- Don't transcribe a video with no speech. If the user wants captions on silent footage, use subtitles_from_visuals (it narrates what's on screen). Never invent a spoken transcript.
- Voiceovers duck other audio by default so they stay audible. Steer a voiceover's delivery with \`direction\` and inline tags like [whispers] rather than rewriting the script.
- generate_image / generate_video / generate_character_video / voiceover_generate / read_subtitles_aloud make media through hosted models (spends the user's Donkey credits, needs sign-in); call them when the user asked for the media itself — a request for the prompt or script gets text in chat. Bundled stock media (stock_search / stock_add) is free — use it when it fits. Media the user attached is in \`media\`; pass those asset ids as generation references when they say "use this", and place project assets in the cut with add_clip when they ask for them there ("make a movie from these photos"). Generated media previews on a chat card the user can expand, drag in, or file away; add it to the timeline (add_to_timeline:true or an index) only when they asked for it in the cut. Write a rich, specific prompt from their shorthand. Video renders take a minute or two.
- You can see and hear: audio the user attaches to their message plays right in it — answer "what does this say" from what you hear, no tool call. For project footage, watch_video samples a source's frames into timestamped contact sheets (scene changes included) — watch before cutting footage you haven't seen; detect_silence finds dead air; capture_frame shows the one rendered frame at the playhead. The watching-and-cutting skill has the flow.`;
}

export const AI_SKILL_INDEX = Object.keys(AI_SKILLS);

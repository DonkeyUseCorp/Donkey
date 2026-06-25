# Shorts

id: shorts
description: Turn a long video or podcast into vertical short-form clips for TikTok, Reels, and Shorts — pick the strong moments, crop to 9:16 tracking whoever is speaking, and burn in captions.
tags: shorts, tiktok, reels, vertical, clips, highlights, podcast, captions, social
keywords: tiktok, reels, shorts, vertical video, 9:16, portrait, clip, clips, highlight, highlights, snippet, snippets, podcast clip, social media clip, captions, subtitles, reframe, repurpose, turn into clips, best moments

Turn a long recording into short vertical clips ready to post. This skill orchestrates the
pieces — the actual download/transcribe/cut/caption commands live in the `media` skill, and the
landscape→vertical speaker-tracking crop is the bundled `reframe` tool. Reach for it on asks like
"make TikToks from this podcast", "cut this interview into Reels", "vertical clips with subtitles".

## The pipeline
1. **Get the source.** A local file is ready to use. A URL: download it with `yt-dlp` (see `media`).
   For a long source, also pull the transcript/captions — reuse the video's own captions when it has
   them (free), otherwise transcribe (see `media`). You need text with timestamps to choose moments.
2. **Pick the moments.** Read the timestamped transcript and choose self-contained spans that land —
   a complete thought with a hook and a payoff, usually 15–60s. Don't cut mid-sentence. Propose the
   moments (with timestamps) and, when the user hasn't said how many, confirm how many clips they want.
3. **Cut each span.** Trim it out with `ffmpeg` (see `media`). Transcribe the *clip* (not the whole
   source) so caption timestamps start at zero and line up.
4. **Reframe to vertical.** Run `reframe --input clip.mp4 --output clip_v.mp4 --aspect 9:16` — it
   crops to 9:16 and follows whoever is talking (a still listener is ignored, and it cuts on scene
   changes). Pass a generous `timeoutSeconds`. This is the step that makes a landscape two-person
   podcast watchable on a phone.
5. **Caption it.** Burn the clip's subtitles onto the vertical file (see `media`), so the text is
   sized to the 9:16 frame. Burned-in captions are what social players expect.

Output one `*_v.mp4` per moment, captioned, in the user's Downloads (or a folder they name).

## Keep in mind
- Reframe first, caption second — captions burned before reframing would get cropped or shrunk.
- A talking-head or multi-person conversation is the sweet spot. Heavy B-roll or fast cutting has no
  single speaker to follow; `reframe` falls back to a centered crop, so a fixed `ffmpeg` crop is just
  as good there — say so rather than implying it tracked a subject.
- Picking the moment is judgment, not a formula: favor a strong opening line and a clear payoff.

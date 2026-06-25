# Shorts

id: shorts
description: Turn a long video or podcast into vertical short-form clips for TikTok, Reels, and Shorts — pick the strong moments, crop to 9:16 tracking whoever is speaking, and burn in captions.
tags: shorts, tiktok, reels, vertical, clips, highlights, podcast, captions, social
keywords: tiktok, reels, shorts, vertical video, 9:16, portrait, clip, clips, highlight, highlights, snippet, snippets, podcast clip, social media clip, captions, subtitles, reframe, repurpose, turn into clips, best moments
tools: shorts.make, user.choose

Turn a long recording into short vertical clips ready to post. Reach for this skill on asks like
"make TikToks from this podcast", "cut this interview into Reels", "vertical clips with subtitles".

## Use `shorts.make` — it runs the whole pipeline in one call

`shorts.make` does the entire job end-to-end: it transcribes the source on-device, picks the strongest
self-contained moments, cuts each one, reframes it to vertical 9:16 following whoever is speaking, and
burns in captions — then returns the finished clip files. Do this in **one** tool call. Do **not** drive
`yt-dlp`/`ffmpeg`/`transcribe`/`reframe` yourself step by step: that path costs a model round-trip at
every step and clip, and `shorts.make` is the supported way to make shorts.

- `source` — a local video path, or a URL (it downloads with `yt-dlp` itself).
- `count` — how many clips. **If the user didn't say how many, ask with `user.choose` before calling.**
  Picking the count is the user's call; everything after it is automatic.
- `aspect` — defaults to `9:16`. Pass `aspect="original"` to caption a clip **without** reframing, e.g.
  "just add subtitles to this video".

The finished `*_captioned.mp4` files come back in the conversation's folder, one per moment.

## What it handles for you

- A talking-head or multi-person conversation is the sweet spot — reframe follows the active speaker and
  cuts on scene changes. Heavy B-roll with no single speaker falls back to a centered crop.
- Captions are burned in (what social players expect); if a clip can't be captioned it still ships,
  reframed, and the summary says which clips fell back.
- Reframe happens before captions, so the text is sized to the 9:16 frame.

For one-off lower-level media work that isn't the full shorts pipeline — a plain trim, a format convert,
reusing a video's existing caption track — see the `media` skill.

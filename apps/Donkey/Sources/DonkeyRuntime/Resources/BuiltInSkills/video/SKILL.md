# Video

id: video
description: Generate a short video clip from a text prompt (or animate a still image) with a generative video model. Use when the user wants a video, clip, animation, or moving footage created from scratch.
tags: video, generate, animation, clip, text-to-video, image-to-video
keywords: video, clip, animation, animate, generate, create, make, footage, movie, scene, motion, text to video, image to video
tools: user.choose, video.generate, shell_exec, files.describe

When someone wants a video *made* — "make a video of …", "generate a clip of …", "animate
this photo" — call `video.generate` with a `prompt` describing the scene, action, camera, and
mood. Pass `inputPath` to animate a still image as the first frame (image-to-video). This is a
generative model: it invents new footage, so it fits imaginative or cinematic asks, not exact
text/data on screen.

## Let the user pick speed/quality first
Video generation is slow and costs real credits, and the trade-offs (speed vs quality, audio on/off)
are the user's call — so DON'T just generate. First call `user.choose` to surface a small options
panel, then read the picks and call `video.generate`. Always GUESS sensible defaults from the request
so they can submit in one tap; only the *defaults* differ run to run.

- **Speed & quality** — a `segmented` field `tier` with options like `fast` ("Quicker, lower cost"),
  `standard` ("Balanced"), `high` ("Best quality, slower"). Default from the words: "quick"/"draft" →
  `fast`; "cinematic"/"high quality"/"best" → `high`; otherwise `standard`.
- **Audio** — a `toggle` field `audio`. Default on, unless they said "silent"/"no sound".
- **Length** — a `segmented` field `length` with options like `4`, `6`, `8` (seconds). Default `8` (a
  reasonable clip length); honor an explicit ask ("a 4 second clip" → default `4`).
- **Aspect ratio** — a `dropdown` (or segmented) field `aspect` with `16:9` and `9:16`. Default `9:16`
  for "reel"/"tiktok"/"short"/"story"/"phone", else `16:9`.

The answer returns as `Selected options: tier=…, audio=…, length=…, aspect=…`. Map it straight onto the
call: `video.generate prompt="…" tier=<tier> audio=<true|false> durationSeconds=<length> aspectRatio=<aspect>`.

## The tool
- `video.generate prompt="…"` writes one `.mp4` to `~/Downloads` and returns its path.
- Optional knobs: `tier` (speed/quality), `audio` ("true"/"false"), `inputPath` (animate a still),
  `aspectRatio` ("16:9" landscape, "9:16" portrait), `durationSeconds`, `negativePrompt`, `outDir`.
- It takes up to a few minutes — the call waits for the clip, so issue it once and let it run;
  do not fire it again thinking it stalled.
- It costs video-generation credits per clip, and a clip is much pricier than an image. For more
  than one clip, say how many and confirm first, then call once per clip.

## Write a good prompt
- Describe the subject, the action, the setting, the camera move, and the mood in one or two
  vivid sentences ("a slow dolly-in on a lighthouse at dusk, waves crashing, moody and cinematic").
- Use `negativePrompt` to exclude things ("no text, no people").
- Match `aspectRatio` to where it'll be used — "9:16" for a phone/Reel, "16:9" for landscape.

## Verify and present
- Confirm the file exists and is real video before claiming success:
  `ffprobe -v error -show_entries format=duration:format_name -of default=nw=1 <path>`.
- A zero-byte file or an ffprobe error means it failed — report it, don't claim success.

## When NOT to use this
- Editing, trimming, transcoding, or subtitling an EXISTING video file → the `media` skill (ffmpeg).
- Downloading a video from a URL → the `media` skill (yt-dlp).
- A still photo or artwork → `image.generate`. A chart/infographic/poster → the `design` skill.
- A slideshow of existing stills → assemble with the `media` skill (ffmpeg), not a generative model.

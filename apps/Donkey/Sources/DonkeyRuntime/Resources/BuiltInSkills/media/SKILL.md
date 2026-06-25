# Media

id: media
description: Expert audio and video — download from a URL with yt-dlp, transcode/trim/extract/grab frames with ffmpeg, transcribe/subtitle/translate, cut filler words or silence with word-level timing, and reframe landscape to vertical 9:16 that tracks the active speaker.
tags: video, audio, media, download, convert, youtube, subtitles, transcribe, edit, reframe, vertical
keywords: video, audio, download, youtube, vimeo, mp4, mp3, convert, trim, clip, extract audio, transcode, frame, subtitle, subtitles, caption, captions, transcribe, transcript, translate, srt, vtt, filler words, remove silence, um, uh, jump cut, tighten, reframe, vertical, 9:16, portrait, tiktok, reels, shorts, crop to vertical, active speaker, follow speaker
tools: media.caption, shell_exec, transcribe, llm.generate, files.write

`yt-dlp` and `ffmpeg`/`ffprobe` are bundled, signed, and on the PATH, so use them
by bare name. They are first-party capability tools: downloading from the user's
URL and writing the output file run immediately, with no consent prompt — just
issue the command, and never fall back to a browser to download.

These are standalone signed binaries, not Python packages: run `yt-dlp` directly,
never through `python3 -m yt_dlp`, `pip`, or `which`. Never probe for or install
Homebrew (or any package manager), and never check whether these tools exist
first — just run them by bare name. The app installs them itself on first launch;
if one is briefly missing the command fails with `command not found`, in which
case say the media tools are still installing and stop. Do not try to install anything.

## Download from a URL (yt-dlp)
- **These calls are slow — always pass `timeoutSeconds`.** Extracting a YouTube page (it solves a JS challenge first) can take ~15s *before any bytes download*, so the default short timeout kills it mid-extract. Pass `timeoutSeconds: 120` on the shell_exec call for every yt-dlp download.
- Always single-quote the URL — `?` and `&` are shell metacharacters: `yt-dlp -P ~/Downloads 'URL'`.
- Default the destination to `~/Downloads`; honor a different folder only if the user names one. yt-dlp already picks the best quality.
- **Pin a known output path so later steps never hunt for the file.** Pass `-o ~/Downloads/clip.%(ext)s` and add `--print after_move:filepath` — yt-dlp prints the EXACT final path (the container may resolve to `.mp4` or `.webm`). Use that path verbatim for ffprobe/ffmpeg; do NOT run `find`/`ls` to go looking for the download, and never re-download to "check" — you already know where it landed.
- A specific time range (a clip) downloads just that span: `yt-dlp --download-sections '*15:00-16:00' -P ~/Downloads 'URL'`.
- Audio only: `yt-dlp -x --audio-format mp3 -P ~/Downloads 'URL'`.
- A specific resolution if asked: `yt-dlp -f 'bestvideo[height<=1080]+bestaudio' -P ~/Downloads 'URL'`.
- **Issue ONE download command and let yt-dlp do its own retries — never fire several attempts in a row.** A burst of repeated calls from the same IP is what *triggers* YouTube's rate-limiting. Add `--retries 5 --extractor-retries 3` so one command rides out a transient hiccup.
- `HTTP 403 Forbidden` on the video stream is almost always that transient rate-limiting, not a dead URL — it usually clears on its own. If a download 403s, wait and retry the SAME command at most once, then report it; do not keep firing variations. `Unable to extract` instead means the bundled yt-dlp is older than the site's latest change — report that plainly, don't retry blindly.

## Edit a local file (ffmpeg)
- Transcode by changing the extension: `ffmpeg -i in.mov out.mp4`.
- Trim without re-encoding: `ffmpeg -ss 00:00:10 -i in.mp4 -t 30 -c copy out.mp4` (start, then 30s).
- Extract audio: `ffmpeg -i in.mp4 -vn -acodec libmp3lame out.mp3`.
- One frame / thumbnail: `ffmpeg -ss 5 -i in.mp4 -frames:v 1 thumb.png`. Frames every second: `ffmpeg -i in.mp4 -vf fps=1 frame_%03d.png`.
- ffmpeg refuses to overwrite by default and prompts; pass `-y` to overwrite or choose a new output name.

## Two ways to transcribe — pick by the timing you need
- **`transcribe` (on-device, word-level).** Runs Apple's local speech engine on an audio file and writes a JSON file holding the plain `text` plus `words` — every word with a `start`/`end` in seconds, accurate to a fraction of a second. Private, no credits. Use it whenever you need to know *exactly when* words are spoken: cutting filler words or silence, finding a quoted moment, chaptering. Hand it compact audio (extract it from a video first); if it reports no transcript, extract audio and retry.
- **`llm.generate` SRT (the model).** Sentence-level cues with approximate timing — fine for subtitles, not precise enough to cut individual words. Use it for translation or when you just need readable captions.

## Subtitles, captions, and translation
**Use the `media.caption` tool — it does the whole job in one call.** Give it the video (a local path or a
URL), and optionally a language to `translateTo` (e.g. "Korean") and a `clipStart`/`clipDuration` to caption
just a span. It transcribes on-device for exact timings, translates with one model call when asked, builds a
clean SRT in code, and burns the captions in with a known-good encoder — then returns the captioned file.

Do **not** hand-build the transcribe → SRT → burn pipeline with `llm.generate` and `ffmpeg`. A model-authored
SRT comes back messy (stray prose, the wrong language, broken cues), so you end up re-cleaning it, writing a
filter script, and debugging encoders and durations — dozens of round-trips for a one-call job. `media.caption`
is built to avoid exactly that.

Reach for raw ffmpeg only to apply a subtitle file the user already has:
- Burn-in: `ffmpeg -i clip.mp4 -vf "subtitles=subs.srt" -c:v libx264 -pix_fmt yuv420p -c:a aac out.mp4`.
- Soft, toggleable track (no libass, no re-encode): `ffmpeg -i clip.mp4 -i subs.srt -c copy -c:s mov_text out.mp4`.

## Cut filler words or silence
Use the **`media.cut`** tool — a deterministic, frame-accurate editor. It does the span math and the ffmpeg render itself; you only say what to remove. Do NOT hand-build select/trim/concat ffmpeg for this.

- **Filler words**: run `transcribe` on the audio first, then `media.cut inputPath=clip.mp4 removeFillers=true transcriptPath=<the transcribe JSON>` — it cuts um/uh/er with the right padding.
- **Silence / dead air**: `media.cut inputPath=clip.mp4 removeSilence=true`.
- **Both at once**: pass `removeFillers=true removeSilence=true` together (still give `transcriptPath`).
- **A specific bad take, or a discourse "like" the lexicon won't catch**: pass `removeSpans="12.4-15.0, 88.0-90.5"` (seconds).

It writes `<name>-tightened.<ext>` next to the source (override with `outputPath`) and reports how much it removed. Finding nothing to cut is a clean result, not an error. Verify the output as below.

## Reframe landscape to vertical (reframe)
`reframe` is bundled alongside ffmpeg. It turns a landscape clip into vertical 9:16 that **follows
whoever is talking** — face tracking plus on-device active-speaker detection — instead of ffmpeg's
fixed-rectangle `crop`. It is fully local (Apple Vision + AVFoundation, no model file, no network)
and keeps the original audio. Use it for any "make this vertical / portrait / for TikTok/Reels/Shorts"
ask on real footage; keep ffmpeg `crop` only when the user wants a fixed, non-tracking crop.
- `reframe --input in.mp4 --output out.mp4 --aspect 9:16 --height 1920` → prints a JSON summary
  (`out`, `width`, `height`, `facesTracked`, `speakersFollowed`, `cuts`). `--aspect` and `--height`
  are optional (default 9:16 at 1920 tall). It analyzes the whole clip, so pass a generous
  `timeoutSeconds` (a minute or so for a long clip).
- It picks the speaking face when several are in frame (a still listener is ignored), smooth-pans to
  follow them, and cuts on scene changes. With no faces it falls back to a centered crop.
- It does **not** add captions. For a captioned vertical clip, reframe first, then burn subtitles
  (above) onto the vertical file so the text is sized to the 9:16 frame. For the full
  podcast/long-video → short-form pipeline, see the `shorts` skill.

## Verify
- Confirm the output exists and is real media: `ffprobe -v error -show_entries format=duration:format_name -of default=nw=1 out.mp4`.
- A zero-byte file or an ffprobe error means the operation failed — report it, don't claim success.
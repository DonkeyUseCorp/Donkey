# Media

id: media
description: Expert audio and video — download from a URL with yt-dlp, transcode/trim/extract/grab frames with ffmpeg, and transcribe, subtitle, or translate with the model.
tags: video, audio, media, download, convert, youtube, subtitles, transcribe
keywords: video, audio, download, youtube, vimeo, mp4, mp3, convert, trim, clip, extract audio, transcode, frame, subtitle, subtitles, caption, captions, transcribe, transcript, translate, srt, vtt
tools: shell_exec, llm.generate

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

## Subtitles & transcription
Get the subtitle text, then apply it. Prefer the cheapest source that gives correct timing.

1. **Reuse the video's own captions first (free — no model call).** Many videos already ship captions; pull them as a sidecar `.srt`:
   `yt-dlp --write-subs --write-auto-subs --sub-langs 'en.*' --convert-subs srt --skip-download -P ~/Downloads 'URL'` (drop `--skip-download` to grab the video too).
2. **Otherwise transcribe with the model.** Timing matters: **clip first, then transcribe the clip** so timestamps start at zero and line up. Extract compact mono audio, then call `llm.generate` with that file:
   - `ffmpeg -i clip.mp4 -vn -ac 1 -c:a libmp3lame -b:a 64k clip.mp3`
   - `llm.generate filePath=clip.mp3 prompt="Transcribe this audio to SRT with timestamps, one cue per sentence" toFile=true` → the returned file holds your SRT text; save/rename it to `subs.srt`.
3. **Translate** by asking in the same call: `prompt="Transcribe this audio and translate the text to Spanish; output SRT, keep the timestamps"`.
4. **Long media — chunk it.** Inline audio is size-limited (`llm.generate` rejects a file that is too large or a transcript it had to truncate — both mean "use smaller chunks"). Split, transcribe each zero-based, then shift by each segment's *real* start:
   - `ffmpeg -i audio.mp3 -f segment -segment_time 600 -reset_timestamps 1 -c copy seg_%03d.mp3` splits into ~10-min pieces.
   - `-c copy` cuts on frame boundaries, so a segment's real length is not exactly 600s. Read each one's true duration with `ffprobe -v error -show_entries format=duration -of csv=p=0 seg_000.mp3` and accumulate; that running sum is the next segment's start offset — do not assume `index × 600`.
   - Transcribe each segment with a plain zero-based prompt (`"Transcribe to SRT with timestamps"`), then add the accumulated offset to every cue in that segment's SRT and concatenate in order, renumbering cue indices. Sanity-check that timestamps only increase.
5. **Apply to the video (ffmpeg):**
   - Burn-in (default for a shareable clip — always-visible, what social players expect): `ffmpeg -i clip.mp4 -vf "subtitles=subs.srt" -c:a copy out.mp4`. The bundled ffmpeg ships with libass, so this works out of the box. If it ever fails with `No such filter: 'subtitles'` (a stripped ffmpeg without libass), fall back to the soft track below and tell the user why.
   - Soft, toggleable track (offer for an archive copy): `ffmpeg -i clip.mp4 -i subs.srt -c copy -c:s mov_text out.mp4`.
- Model timestamps are approximate (good enough for subtitles); always extract audio before transcribing, and chunk long files.

## Verify
- Confirm the output exists and is real media: `ffprobe -v error -show_entries format=duration:format_name -of default=nw=1 out.mp4`.
- A zero-byte file or an ffprobe error means the operation failed — report it, don't claim success.
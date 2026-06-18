# Media

id: media
description: Expert audio and video — download from a URL with yt-dlp, then transcode, trim, extract audio, or grab frames with ffmpeg.
tags: video, audio, media, download, convert, youtube
keywords: video, audio, download, youtube, vimeo, mp4, mp3, convert, trim, clip, extract audio, transcode, frame
tools: shell_exec

`yt-dlp` and `ffmpeg`/`ffprobe` are bundled and on the PATH, so use them by bare
name. Downloading and writing files is reversible — propose the command and let
the consent gate handle approval; do not fall back to a browser.

## Download from a URL (yt-dlp)
- Always single-quote the URL — `?` and `&` are shell metacharacters: `yt-dlp -P ~/Downloads 'URL'`.
- Default the destination to `~/Downloads`; honor a different folder only if the user names one. yt-dlp already picks the best quality.
- Audio only: `yt-dlp -x --audio-format mp3 -P ~/Downloads 'URL'`.
- A specific resolution if asked: `yt-dlp -f 'bestvideo[height<=1080]+bestaudio' -P ~/Downloads 'URL'`.
- `Unable to extract` / `HTTP 403` usually means the bundled yt-dlp is older than the site's latest change, not a bad URL — report that plainly; do not retry blindly.

## Edit a local file (ffmpeg)
- Transcode by changing the extension: `ffmpeg -i in.mov out.mp4`.
- Trim without re-encoding: `ffmpeg -ss 00:00:10 -i in.mp4 -t 30 -c copy out.mp4` (start, then 30s).
- Extract audio: `ffmpeg -i in.mp4 -vn -acodec libmp3lame out.mp3`.
- One frame / thumbnail: `ffmpeg -ss 5 -i in.mp4 -frames:v 1 thumb.png`. Frames every second: `ffmpeg -i in.mp4 -vf fps=1 frame_%03d.png`.
- ffmpeg refuses to overwrite by default and prompts; pass `-y` to overwrite or choose a new output name.

## Verify
- Confirm the output exists and is real media: `ffprobe -v error -show_entries format=duration:format_name -of default=nw=1 out.mp4`.
- A zero-byte file or an ffprobe error means the operation failed — report it, don't claim success.
# Images

id: images
description: Expert still-image work — resize/convert/rotate with sips, crop/composite with magick, metadata with exiftool, batch a folder, and generative edits (background removal, restyle, reference-match, text-to-image) with the image.* tools.
tags: image, photo, resize, convert, metadata, exif, generate, edit
keywords: image, photo, picture, draw, comic, comic strip, cartoon, resize, scale, convert, crop, rotate, jpeg, png, heic, metadata, exif, strip, batch, folder, background, remove, restyle, generate, reference, match, look
tools: shell_exec, image.edit, image.generate, files.describe

Two kinds of work: mechanical pixels (size, format, crop, metadata) use the local
tools; semantic changes (remove a background, restyle, add or remove an object,
match another photo's look, make an image from scratch) use the generative
`image.*` tools. `sips` and `exiftool` are bundled; reach for `magick` (ImageMagick)
directly and fall back to `sips` if it isn't installed. Editing in place is reversible
(consent gate); a new `--out` path is safer — prefer it when the original should survive.

## sips — resize, convert, rotate (writes a new file with --out)
- Resize to a max dimension, aspect preserved: `sips -Z 1024 in.jpg --out small.jpg`.
- Convert format: `sips -s format jpeg in.png --out out.jpg` (formats: jpeg, png, tiff, gif, pdf).
- Rotate: `sips -r 90 in.jpg --out rotated.jpg` (degrees clockwise).
- Image to PDF: `sips -s format pdf in.png --out out.pdf`.
- Read dimensions: `sips -g pixelWidth -g pixelHeight in.jpg`.

## magick — crop, composite (only if installed)
- Crop a region WxH+X+Y: `magick in.png -crop 200x200+0+0 out.png`.
- If `magick` isn't installed (the command fails with `command not found`), do what `sips` can and say plainly what needs ImageMagick; do not pretend it ran.

## exiftool — read and strip metadata
- Read all metadata: `exiftool in.jpg`. One tag: `exiftool -GPSLatitude -GPSLongitude in.jpg`.
- Strip everything (privacy): `exiftool -all= in.jpg` — keeps a `in.jpg_original` backup; delete it only if the user confirms.

## Batch a folder (write copies, never in place)
- `sips` processes many inputs when `--out` is a directory: `mkdir -p edited && sips -Z 2048 *.jpg --out edited` resizes every jpg into `edited/`; same for convert: `sips -s format jpeg *.png --out edited`.
- A bare glob that matches nothing ABORTS under zsh — confirm matches first with `ls *.jpg` (or `ls | grep -iE '\.jpe?g$'`), then run. Keep parentheses out of commands (the classifier splits on them).
- `exiftool` takes a folder: `exiftool -all= -o edited/ *.jpg`. `magick mogrify -path edited -resize 2048x2048 *.jpg` writes resized copies into `edited/` (plain `mogrify` without `-path` edits the originals — confirm first).
- Report how many files changed and re-read one to verify.

## Generative edits — image.edit / image.generate
- Change an existing image: `image.edit` with `inputPath` and a plain-words `prompt` ("remove the background", "make the sky a sunset", "put a hat on the dog"). It writes a NEW file and returns its path; it never touches the source.
- New PHOTO or ARTWORK from text: `image.generate` with a `prompt`. But to CREATE an infographic, diagram, chart, poster, or any image of text/data, do NOT use `image.generate` (it garbles text) — follow the `design` skill: write HTML/SVG and render it with `image_render`.
- A COMIC or comic strip is one `image.generate` call: describe the panel count and layout, what happens in each panel, the art style, and any short speech-bubble or caption lines in quotes. The model draws the whole multi-panel page, bubbles included. If the user wants more pages, call once per page reusing the first page as `referencePaths` via `image.edit` so characters stay consistent.
- These cost credits per image. For a batch, say how many and confirm first, then call `image.edit` once per file (e.g. saving into `edited/`).
- Verify the returned file exists and looks right (`files.describe` or open it), then report what was saved.

## Match a reference photo's look
- Generative (handles colour grade, mood, lighting, style): `image.edit` with the target as `inputPath`, the reference as `referencePaths`, and a `prompt` like "edit the first image to match the colour and lighting of the reference". Loop per file for a batch.
- Tone/exposure only, no credits, needs magick: read both images' channel means (`magick in.jpg -format "%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]" info:`) and nudge with `-modulate`/`-channel`; for anything past white balance and brightness use the generative path.

## Verify
- Re-read the result: `sips -g pixelWidth -g pixelHeight out.jpg`, `exiftool out.jpg` after stripping to confirm tags are gone, or `files.describe` for a generative output.

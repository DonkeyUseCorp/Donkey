# Images

id: images
description: Expert still-image work — resize, convert, and rotate with sips, crop/composite/batch with magick, and read or strip metadata with exiftool.
tags: image, photo, resize, convert, metadata, exif
keywords: image, photo, picture, resize, scale, convert, crop, rotate, jpeg, png, heic, metadata, exif, strip
tools: shell_exec

`sips` ships with macOS and `exiftool` is bundled and on the PATH — lead with
those; they cover almost every request. `magick` (ImageMagick) is only available
when the user has installed it (check the ENVIRONMENT tool list), so reach for it
only for what `sips` can't do. Editing a file in place is reversible (consent
gate); writing to a new `--out` path is safer, so prefer it when the user wants
to keep the original.

## sips — resize, convert, rotate (writes a new file with --out)
- Resize to a max dimension, aspect preserved: `sips -Z 1024 in.jpg --out small.jpg`.
- Convert format: `sips -s format jpeg in.png --out out.jpg` (formats: jpeg, png, tiff, gif, pdf).
- Rotate: `sips -r 90 in.jpg --out rotated.jpg` (degrees clockwise).
- Image to PDF: `sips -s format pdf in.png --out out.pdf`.
- Read dimensions: `sips -g pixelWidth -g pixelHeight in.jpg`.

## magick — crop, composite, batch (only if installed)
- Crop a region WxH+X+Y: `magick in.png -crop 200x200+0+0 out.png`.
- Batch convert a folder: `magick mogrify -format jpg *.png`. NOTE `mogrify` edits or replaces files in place — confirm before running it on originals.
- If `magick` is not in the ENVIRONMENT list, do what `sips` can and say plainly what needs ImageMagick; do not pretend it ran.

## exiftool — read and strip metadata
- Read all metadata: `exiftool in.jpg`. One tag: `exiftool -GPSLatitude -GPSLongitude in.jpg`.
- Strip everything (privacy): `exiftool -all= in.jpg` — keeps a `in.jpg_original` backup; delete it only if the user confirms.

## Verify
- Re-read the result: `sips -g pixelWidth -g pixelHeight out.jpg`, or `exiftool out.jpg` after stripping to confirm the tags are gone.
# epub-pack

A tiny native macOS CLI that packages a folder of authored XHTML pages (plus their
images) into a valid EPUB 3, and validates one. It is the EPUB counterpart to the
`image_render` PDF path: the model authors the page markup, and this assembles the
finicky, deterministic parts — the mimetype-first/stored ZIP layout, the OPF
manifest+spine, the EPUB3 `nav.xhtml`, and a compatibility `toc.ncx`. It uses only
Foundation (a self-contained store-only ZIP writer + CRC32), so it ships as a single
self-contained binary with no third-party dependency.

`scripts/fetch-bundled-tools.sh` compiles `main.swift` into
`vendor/donkey-tools/epub-pack`, which packaging stages into the app and which the
`book` skill calls via `shell_exec`.

## Build

```sh
swiftc -O tools/epub-pack/main.swift -o epub-pack
```

## Subcommands

All output is JSON. Errors print `{"error":"…"}` to stderr and exit non-zero.
`--meta` accepts a file path or `-` for stdin.

| Command | Purpose |
|---|---|
| `epub-pack build <pagesDir> --meta book.json -o out.epub` | Package every file under `<pagesDir>` (XHTML pages + images, relative paths preserved) into `out.epub`, generating the OPF/nav/ncx from `book.json`. Prints `{out, pageCount, fileCount, layout, bytes}`. |
| `epub-pack validate <file.epub>` | Structural sanity check: `mimetype` is the first entry, stored, and equals `application/epub+zip`; the container and OPF are present. Prints `{valid: true}` or `{valid: false, problems: [...]}` (exit 2). |

## `book.json`

```json
{
  "title": "Swim Day",
  "author": "David & Son",
  "language": "en",
  "identifier": "urn:uuid:…",
  "cover": "cover.xhtml",
  "coverImage": "img/cover.jpg",
  "layout": "fixed",
  "spine": ["cover.xhtml", "p01.xhtml", "p02.xhtml"]
}
```

- `spine` is required: the reading order, as page-file paths relative to `<pagesDir>`.
  Entries may be strings or `{ "file": "p01.xhtml" }` objects.
- `layout` defaults to `reflow`. Use `fixed` for comics/picture books — it adds
  `rendition:layout = pre-paginated` to the OPF. Each fixed-layout page should declare
  its own `<meta name="viewport" content="width=W, height=H"/>` in its `<head>`.
- `identifier` defaults to a generated `urn:uuid:` if absent.
- `coverImage` (optional) marks that image with `properties="cover-image"` and the
  legacy `<meta name="cover">` so readers show a thumbnail.

## Notes

- Every entry is stored (uncompressed). EPUB only requires the `mimetype` entry to be
  stored-and-first; storing the rest keeps the writer dependency-free and is lossless
  on already-compressed images (JPEG/PNG). XHTML/OPF are tiny, so size is a non-issue.
- Images may instead be inlined into the XHTML as `data:` URIs (the same approach the
  `design` skill uses), in which case `<pagesDir>` holds only the page files.
- Files and folders beginning with `.` (e.g. `.DS_Store`) are skipped.

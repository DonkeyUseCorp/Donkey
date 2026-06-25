# pdf-fill

A tiny native macOS CLI for filling PDFs headlessly. It is the write counterpart
to litparse (`lit`), which only reads. It uses Apple system frameworks
(PDFKit/Quartz) only — no third-party dependency — so it ships as a single
self-contained binary.

`scripts/fetch-bundled-tools.sh` compiles `main.swift` into
`vendor/donkey-tools/pdf-fill`, which packaging stages into the app and which the
`pdf` skill calls via `shell_exec`.

## Build

```sh
swiftc -O tools/pdf-fill/main.swift -o pdf-fill
```

## Subcommands

Output is JSON except for `form`, which is a plain-text page view. Errors print
`{"error":"…"}` to stderr and exit non-zero. `--data` accepts a file path or `-`
for stdin. Coordinates are PDF points from the **bottom-left** of the page.

| Command | Purpose |
|---|---|
| `pdf-fill list <in.pdf>` | List fillable AcroForm fields: `{name, type, value, page, rect, options?}`. An empty array means the PDF has no fillable fields — use `overlay`. Output is always indented; `--pretty` is accepted as a no-op so `pdf-fill list in.pdf --pretty > fields.json` works. |
| `pdf-fill pages <in.pdf>` | Per-page sizes: `{page, width, height}`. Use the height to convert a top-left parser's y (`y_pdf = height - y_top - h`). |
| `pdf-fill form <in.pdf> [--page N] [--part K]` | Reading-order view of ONE page: printed text top-to-bottom, left-to-right, with fields interleaved inline where they sit — `⟦id⟧` (text), `⟦x id=on⟧` (checkbox, `on` ticks it), `⟦? id=a\|b⟧` (dropdown). `id` is the field's short leaf (`f1_4[0]`), which `set` resolves back to the full name. Lets a reader bind values the way a person reads the paper form instead of guessing a label per field by coordinates. Default page 0; `--page N` (0-indexed) picks a page; a dense page splits into `--part K` chunks that each fit the caller's output budget — a footer shows the next page/part. Text comes from PDFKit's `characterBounds`, in the same bottom-left space as the fields (no coordinate flip). |
| `pdf-fill set <in.pdf> --data map.json -o out.pdf` | Set field values from a `{id: value}` map. `id` is either a full field name or the short id `form` shows (`f1_4[0]`, or `f1_4` without the widget index when unambiguous). Text/choice take strings; checkboxes take the on-value (or `true`/`false`/on/off). Reports `applied`, `missing`, and `ambiguous` (an id matching several fields — add the widget index). |
| `pdf-fill overlay <in.pdf> --data items.json -o out.pdf` | Stamp text onto a flat PDF from `[{page, x, y, text, size?, width?, height?}]`. Numeric fields accept JSON numbers or numeric strings. Invalid items are skipped (not fatal); the result reports `stamped` and any `skipped` items with `{index, reason}`. Fails only if nothing could be stamped. |
| `pdf-fill flatten <in.pdf> -o out.pdf` | Burn form values and overlays into page content (non-editable, text stays selectable). Reports `processedPages`/`totalPages`; if any page could not be read it adds `droppedPages` and a `warning` instead of reporting a clean success. |

## Notes

- Field names are the widget's partial `/T` entry — correct for the flat,
  non-hierarchical AcroForms that cover almost all real-world forms. Deeply nested
  field hierarchies are not resolved.
- Setting a value regenerates the field appearance, so viewers render it without a
  separate `NeedAppearances` pass.
- Password-protected PDFs are rejected; decrypt first
  (`qpdf --password=… --decrypt in.pdf out.pdf`).
- Digital signatures and pure-XFA dynamic forms are out of scope. XFA-*hybrid*
  forms (which also carry a normal AcroForm layer, like IRS tax forms) work through
  that layer — `list`, `form`, and `set` operate on it.

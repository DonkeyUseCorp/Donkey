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

All output is JSON. Errors print `{"error":"…"}` to stderr and exit non-zero.
`--data` accepts a file path or `-` for stdin. Coordinates are PDF points from the
**bottom-left** of the page.

| Command | Purpose |
|---|---|
| `pdf-fill list <in.pdf>` | List fillable AcroForm fields: `{name, type, value, page, rect, options?}`. An empty array means the PDF has no fillable fields — use `overlay`. |
| `pdf-fill pages <in.pdf>` | Per-page sizes: `{page, width, height}`. Use the height to convert a top-left parser's y (`y_pdf = height - y_top - h`). |
| `pdf-fill set <in.pdf> --data map.json -o out.pdf` | Set field values from a `{fieldName: value}` map. Text/choice take strings; checkboxes take `true`/`false` (or on/off). Reports `applied` and `missing`. |
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
- Digital signatures and XFA forms are out of scope.

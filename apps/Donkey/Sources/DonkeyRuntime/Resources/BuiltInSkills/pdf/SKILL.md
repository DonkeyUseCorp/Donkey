# PDF

id: pdf
description: Expert headless PDF and document work — extract text and structured data with liteparse, fill forms with pdf-fill, merge/split/rotate with qpdf, and convert document formats with textutil.
tags: pdf, document, convert, merge, split, ocr, extract, fill, form
keywords: pdf, extract, parse, text, ocr, scan, json, merge, combine, split, extract pages, rotate, convert, docx, rtf, html, fill, form, fillable, acroform, checkbox
tools: shell_exec

`lit` (liteparse), `pdf-fill`, and `qpdf` are bundled and on the PATH; `textutil`
and `mdls` ship with macOS. This is the headless path — fill a form right here with
`pdf-fill`; only drop to the `documents` skill when the user wants to watch it
happen in Preview. Creating files is reversible (consent gate).

## qpdf — structure (page order in, page order out)
- Merge: `qpdf --empty --pages a.pdf b.pdf -- out.pdf`.
- Extract / split a range: `qpdf in.pdf --pages in.pdf 1-5 -- out.pdf`.
- Rotate page 1 by 90°: `qpdf in.pdf --rotate=+90:1 -- out.pdf`.
- Remove a known password: `qpdf --password=PW --decrypt in.pdf out.pdf`.
- Page count: `qpdf --show-npages in.pdf`.

## Convert document formats (textutil, built into macOS)
- `textutil` converts among txt, html, rtf, doc, docx, odt with no extra tools: `textutil -convert docx in.html -output out.docx`, `textutil -convert txt in.docx -output out.txt`, `textutil -convert html in.rtf -output out.html`.
- Markdown, LaTeX, and EPUB are NOT covered by textutil and need `pandoc`, which is not bundled — run `pandoc in.md -o out.docx` directly, and if it isn't installed (`command not found`), say plainly that those formats need pandoc installed.
- To make a PDF from a document: convert it to HTML with textutil, then render that HTML to PDF via the `web-capture` skill (headless print).

## Extract text or structured data from a PDF — use liteparse (`lit`)
- `lit` handles both digital and scanned PDFs; OCR is built in, so there is no separate rasterize/OCR step.
- Plain text: `lit parse in.pdf`. Specific pages: `lit parse in.pdf --target-pages "1-5,10"`.
- Structured JSON (per-element text with layout/bounding boxes — use this when the task needs fields, tables, or positions): `lit parse in.pdf --format json -o out.json`.
- Skip OCR for a known-digital PDF to go faster: `lit parse in.pdf --no-ocr`.
- For just a title/metadata lookup without parsing, `mdls -name kMDItemTitle in.pdf` still works.

## Fill a PDF form — use pdf-fill (`pdf-fill`)
`pdf-fill` writes a NEW file; it never edits in place. All I/O is JSON. Start by asking it what kind of form this is:
- `pdf-fill list in.pdf --pretty > fields.json` — ALWAYS redirect the field list to a file. A real form (a tax or government form) has hundreds of fields; dumping that to stdout floods the next step's context and times out the read on volume. Write it to a file, then inspect it (`head`, count with a `lit`/`jq` pass), and work from the file.
- The list entries are `{name, type, value, page, rect}`. Field NAMES on official forms are opaque (`topmostSubform[0].Page1[0].f1_11[0]`) and carry no meaning on their own, so you must recover what each field IS before filling it — don't guess from the name.

### Filling an official form (tax / government / insurance) — recover labels, then map and compute
Opaque field names plus loose source data is a mapping problem, not a typing problem. Plan it as **read the data → recover each field's label → map data to fields → compute the derived values → write → verify**, and front-load the mapping and computation rather than circling the easy reads.
- Recover labels by position: a field's caption is the text printed next to it. Get the page text with boxes (`lit parse in.pdf --format json`) and join each field's `rect` from `pdf-fill list` to the nearest text run (the label is usually just left of, or above, the box). pdf-fill rects are bottom-left-origin PDF points; lit boxes are top-left — convert with the page height from `pdf-fill pages in.pdf`. Now you have `field → label`, which is what to map the data onto.
- Map the source data to fields by MEANING (you do this — match "gross receipts/total sales" to the receipts line, "officer compensation" to that line, etc.), then build the `{fieldName: value}` object and write it with `pdf-fill set`.
- Compute the derived values the data doesn't state outright — most official forms have them. A 1120, for instance, needs net receipts (gross − returns), total income, total deductions, taxable income, and tax (21% of taxable income). Work these out explicitly before filling; don't leave them blank and don't expect them in the data.
- If labels can't be recovered from the text layer (a scanned/flattened form), fall back to vision: rasterize a page (`lit screenshot`) and read the layout.
- **Has fields (non-empty list) → set them.** Build a `{fieldName: value}` map and pipe it in: `echo '{"FullName":"Ada","Agree":true}' | pdf-fill set in.pdf --data - -o out.pdf`. Text and dropdown fields take strings; checkboxes take `true`/`false`. The result reports `applied` and `missing` so you can see any name that did not match.
- **No fields (empty list) → it is a flat or scanned form; overlay text by position.** Get the labels and their boxes with `lit parse in.pdf --format json`, then stamp values next to them: `echo '[{"page":0,"x":120,"y":700,"text":"Ada Lovelace","size":12}]' | pdf-fill overlay in.pdf --data - -o out.pdf`. Coordinates are PDF points from the BOTTOM-left; lit boxes are top-left, so convert with the page height from `pdf-fill pages in.pdf` (`y_pdf = height - y_top - h`). Valid stamps are written even if some items are bad; the result reports `stamped` and any `skipped` items (with index and reason), so check `skipped` to catch dropped values.
- To make the result non-editable (e.g. before sending it on), `pdf-fill flatten out.pdf -o final.pdf` burns the values into the page. It reports `processedPages`/`totalPages`; if it includes `droppedPages`/`warning`, some pages were lost — do not treat that output as complete.
- Ask the user for any value you do not have before filling; do not invent field contents.

## Verify
- After a structural edit, confirm with `qpdf --show-npages out.pdf` or re-read the text with `mdls`. After a conversion, confirm the output file exists and opens.
- After filling, re-run `pdf-fill list out.pdf` and check the values are present (for an overlay, flatten then `lit parse` the result).
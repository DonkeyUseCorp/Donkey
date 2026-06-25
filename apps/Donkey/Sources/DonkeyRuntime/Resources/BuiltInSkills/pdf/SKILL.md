# PDF

id: pdf
description: Expert headless PDF and document work — fill forms with pdf-fill, extract text and structured data with liteparse, merge/split/rotate with qpdf, and convert document formats with textutil.
tags: pdf, document, convert, merge, split, ocr, extract, fill, form
keywords: pdf, extract, parse, text, ocr, scan, json, merge, combine, split, extract pages, rotate, convert, docx, rtf, html, fill, form, fillable, acroform, checkbox
tools: shell_exec

`pdf-fill`, `lit` (liteparse), and `qpdf` are bundled and on the PATH; `textutil` and `mdls` ship with macOS. This is the headless path — fill, parse, and convert right here; only drop to the `documents` skill when the user wants to watch it in Preview. Files you create are reversible (consent gate), and your shell runs in your working directory, so use BARE filenames (`f1120.pdf`, `out.pdf`), never your home root.

## Fill a PDF form — `pdf.fill`
A fillable form (an IRS/tax/government/insurance PDF with fillable fields) is filled in ONE call to the `pdf.fill` tool: give it `form` (the PDF) and `data` (a data file path, or the values as text). It reads the whole form, maps every value it can — entity name, address, ID numbers, every money line, and the totals it must compute (net receipts, total income/deductions, taxable income, tax) — writes a NEW filled PDF (`out.pdf` by default, or pass `out`), and reports what it applied and what it could not place. Do NOT run `pdf-fill` by hand, dump the field list, or read the form field-by-field — `pdf.fill` is the whole job. Ask for any value you don't have; don't invent field contents.

Flat or scanned form (no fillable fields — a page is just printed text or a scan): there is nothing for `pdf.fill` to fill, so overlay by position. Get label boxes with `lit parse in.pdf --format json`, then `echo '[{"page":0,"x":120,"y":700,"text":"Ada Lovelace","size":12}]' | pdf-fill overlay in.pdf --data - -o out.pdf`. Coordinates are PDF points from the BOTTOM-left; lit boxes are top-left, so convert with `pdf-fill pages in.pdf` (`y_pdf = height - y_top - h`). The result reports `stamped` and any `skipped`. `pdf-fill flatten out.pdf -o final.pdf` burns values in (non-editable) and warns on `droppedPages`.

## Extract text or structured data — liteparse (`lit`)
- `lit` handles both digital and scanned PDFs; OCR is built in, so there is no separate rasterize/OCR step.
- Plain text: `lit parse in.pdf`. Specific pages: `lit parse in.pdf --target-pages "1-5,10"`. Skip OCR on a known-digital PDF to go faster: `--no-ocr`.
- Structured JSON (per-element text with layout/bounding boxes — for tables or positions): `lit parse in.pdf --format json -o out.json`.
- Just a title/metadata lookup: `mdls -name kMDItemTitle in.pdf`.

## Restructure and convert
- qpdf (page order in, page order out): merge `qpdf --empty --pages a.pdf b.pdf -- out.pdf`; split a range `qpdf in.pdf --pages in.pdf 1-5 -- out.pdf`; rotate `qpdf in.pdf --rotate=+90:1 -- out.pdf`; remove a known password `qpdf --password=PW --decrypt in.pdf out.pdf`; page count `qpdf --show-npages in.pdf`.
- textutil (txt/html/rtf/doc/docx/odt, built into macOS): `textutil -convert docx in.html -output out.docx`. Markdown, LaTeX, and EPUB need `pandoc` (not bundled — run it directly, and if `command not found`, say those formats need pandoc installed). To make a PDF from a document: convert it to HTML with textutil, then render that HTML to PDF via the `web-capture` skill.

## Verify
- `pdf.fill` already verifies its own output and reports the applied fields. For an overlay, flatten then `lit parse` the result to confirm the values are present.
- After a structural edit, `qpdf --show-npages out.pdf`; after a conversion, confirm the output file exists and opens.

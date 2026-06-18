# PDF

id: pdf
description: Expert headless PDF and document work — extract text and structured data with liteparse, merge/split/rotate with qpdf, and convert document formats with textutil.
tags: pdf, document, convert, merge, split, ocr, extract
keywords: pdf, extract, parse, text, ocr, scan, json, merge, combine, split, extract pages, rotate, convert, docx, rtf, html
tools: shell_exec

`lit` (liteparse) and `qpdf` are bundled and on the PATH; `textutil` and `mdls`
ship with macOS. This is the headless path — for interactive Preview work
(filling a form, watching a rotation), use the `documents` skill instead.
Creating files is reversible (consent gate).

## qpdf — structure (page order in, page order out)
- Merge: `qpdf --empty --pages a.pdf b.pdf -- out.pdf`.
- Extract / split a range: `qpdf in.pdf --pages in.pdf 1-5 -- out.pdf`.
- Rotate page 1 by 90°: `qpdf in.pdf --rotate=+90:1 -- out.pdf`.
- Remove a known password: `qpdf --password=PW --decrypt in.pdf out.pdf`.
- Page count: `qpdf --show-npages in.pdf`.

## Convert document formats (textutil, built into macOS)
- `textutil` converts among txt, html, rtf, doc, docx, odt with no extra tools: `textutil -convert docx in.html -output out.docx`, `textutil -convert txt in.docx -output out.txt`, `textutil -convert html in.rtf -output out.html`.
- Markdown, LaTeX, and EPUB are NOT covered by textutil and need `pandoc`, which is not bundled — use it only when the ENVIRONMENT lists it (`pandoc in.md -o out.docx`); otherwise say plainly that those formats need pandoc installed.
- To make a PDF from a document: convert it to HTML with textutil, then render that HTML to PDF via the `web-capture` skill (headless print).

## Extract text or structured data from a PDF — use liteparse (`lit`)
- `lit` handles both digital and scanned PDFs; OCR is built in, so there is no separate rasterize/OCR step.
- Plain text: `lit parse in.pdf`. Specific pages: `lit parse in.pdf --target-pages "1-5,10"`.
- Structured JSON (per-element text with layout/bounding boxes — use this when the task needs fields, tables, or positions): `lit parse in.pdf --format json -o out.json`.
- Skip OCR for a known-digital PDF to go faster: `lit parse in.pdf --no-ocr`.
- For just a title/metadata lookup without parsing, `mdls -name kMDItemTitle in.pdf` still works.

## Verify
- After a structural edit, confirm with `qpdf --show-npages out.pdf` or re-read the text with `mdls`. After a conversion, confirm the output file exists and opens.
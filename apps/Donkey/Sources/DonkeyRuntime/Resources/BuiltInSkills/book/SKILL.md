# Book

id: book
description: Make an ebook from scratch — a comic, picture book, photo book, or storybook — and open it in Apple Books. Author each page as HTML, render a multi-page PDF with image_render, and build a real .epub with epub-pack, then open both in Books.
tags: book, ebook, epub, comic, picture-book, photo-book, storybook
keywords: ebook, book, epub, comic, comic book, graphic novel, picture book, photo book, storybook, story, children's book, pages, cover, chapter, apple books, books app, publish
apps: Books, com.apple.iBooksX
tools: image_render, image.generate, image.edit, shell_exec, files.write, files.describe, llm.generate

When someone wants a *book* made — "make a comic book about …", "turn these photos into an
ebook", "a picture book for my son" — you author the pages yourself and package two
deliverables: a **PDF** and a real **.epub**, both of which open in Apple Books. You design
each page as HTML (the reliable way to keep text and layout sharp — see the `design` skill),
render the PDF with `image_render`, and assemble the EPUB with the bundled `epub-pack` tool.
Both land in the conversation's workspace folder, then you open them in Books.

Use a **fixed page layout** for anything image-driven (a comic, a photo book): one image
per page, captions and speech bubbles drawn over it. Use **reflowable** text for a prose
storybook. Creating files is reversible (no consent prompt; `epub-pack` is bundled).

## 1. Gather the material
- The user's supplied images arrive as workspace inputs; if you don't have them, ask for the
  folder or paths. Downscale page-sized photos so the book isn't huge:
  `sips -Z 1600 in.jpg --out pages/img/p01.jpg`.
- Draft the words with `llm.generate`: the through-line, a caption or one or two lines of
  speech-bubble text per page, a title. Keep it to what each page needs.
- Make a cover: compose it as HTML (title over a hero image), or generate art with
  `image.generate`. A restyle of a supplied photo ("make this look like a watercolor comic
  panel") is `image.edit`.

## 2. Author the pages (one XHTML per page)
- Write each page as a self-contained **XHTML** file into the workspace `pages/` folder with
  `files.write`: `pages/cover.xhtml`, `pages/p01.xhtml`, … Cover/title first.
- Inline each image as a `data:` URI (remote and absolute-path images do not load), or place
  it in `pages/img/` and reference it relatively — `epub-pack` carries both. Use system fonts
  (`-apple-system, "Helvetica Neue", Arial, sans-serif`). Draw speech bubbles and captions
  with CSS over the image. Follow the `design` skill for a real visual concept, not a box of text.
- Pick ONE fixed page size and use it everywhere (e.g. 1200×1600 portrait). For a fixed-layout
  book, put `<meta name="viewport" content="width=1200, height=1600"/>` in each page's `<head>`
  so Books renders it pre-paginated.

## 3. Make the PDF
- Render each page to its own one-page PDF, then merge — this guarantees exact page breaks:
  `image_render` with that page's `html`, `width=1200`, `height=1600`, `format=pdf`,
  `destination=pdf/p01.pdf` (repeat per page), then
  `qpdf --empty --pages pdf/cover.pdf pdf/p01.pdf … -- book.pdf` (see the `pdf` skill).

## 4. Build the EPUB
- Write `book.json` with `files.write`:
  `{"title":"…","author":"…","language":"en","layout":"fixed","cover":"cover.xhtml","spine":["cover.xhtml","p01.xhtml",…]}`
  (`layout":"reflow"` for a prose book). The `spine` is the page order.
- `epub-pack build ./pages --meta book.json -o book.epub` — it runs immediately (bundled),
  generates the OPF/nav/toc and the mimetype-first zip, and prints `{pageCount, …}`.
- Confirm it: `epub-pack validate book.epub`.

## 5. Put it in Apple Books
- `open -a Books book.epub` (and/or `open -a Books book.pdf`), then `wait` ~2s for the import.
- Verify Books came forward and the title is in the library (observe Books, or
  `ls -t ~/Library/...` is not needed — a screen observe is enough). Tell the user the
  workspace folder and how many pages.

## Verify
- `epub-pack validate book.epub` → `{"valid":true}`; `qpdf --show-npages book.pdf` matches the
  page count; `files.describe` both outputs exist and are non-empty.
- A failed `epub-pack` or an empty file means it did not work — report it, don't claim success.

## When NOT to use this
- A single infographic, poster, or diagram → the `design` skill (one `image_render`).
- Filling or merging an EXISTING PDF → the `pdf` skill. Reading a PDF's text → `pdf`/`documents`.
- One photo or piece of art → `image.generate` / `image.edit`.

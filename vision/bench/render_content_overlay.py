#!/usr/bin/env python3
"""Draw each parsed element's content onto the screenshot.

Every box is outlined and labeled with "AI <content>" — the content the model
pulled out of it (OCR text for text regions, Florence-2 captions for icons).
Boxes are colored from a per-index palette so adjacent ones read apart, the same
color scheme the worker's numbered output uses; the label is white/black text on
a chip in that color.

Needs Pillow (in vision/bench/.venv). Run it on a result dir from
bench_endpoint.py:

    vision/bench/.venv/bin/python vision/bench/render_content_overlay.py \
        --result-dir vision/bench/results/desktop --image ~/Desktop/desktop.png

Writes `<stem>.content.png` next to the elements JSON.
"""

import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont

# Distinct per-index palette (Apple system colors) cycled by element index, so
# adjacent boxes read apart.
PALETTE = [
    (255, 59, 48), (255, 149, 0), (255, 204, 0), (52, 199, 89),
    (0, 199, 190), (48, 176, 199), (0, 122, 255), (88, 86, 214),
    (175, 82, 222), (255, 45, 85), (162, 132, 94), (142, 142, 147),
]


def color_for(index):
    return PALETTE[index % len(PALETTE)]


def text_on(color):
    # Black on light chips, white on dark — keep the label legible.
    r, g, b = color
    return (0, 0, 0) if (0.299 * r + 0.587 * g + 0.114 * b) > 150 else (255, 255, 255)


def load_font(size):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def render(image_path, elements_path, out_path):
    elements = json.load(open(elements_path))["parsed_content_list"]
    img = Image.open(image_path).convert("RGB")
    W, H = img.size
    draw = ImageDraw.Draw(img, "RGBA")
    font = load_font(max(11, W // 130))
    line_w = max(2, round(W / 1100))

    drawn = 0
    for index, el in enumerate(elements):
        x1, y1, x2, y2 = el["bbox"]
        if x2 <= x1 or y2 <= y1:
            continue
        box = (x1 * W, y1 * H, x2 * W, y2 * H)
        color = color_for(index)
        draw.rectangle(box, outline=color + (255,), width=line_w)

        # App-style label: "AI <content>" on a chip in this box's color.
        content = (el.get("content") or "").strip() or (el.get("type") or "element")
        label = f"AI {content}"
        tb = draw.textbbox((0, 0), label, font=font)
        tw, th = tb[2] - tb[0], tb[3] - tb[1]
        lx = box[0]
        ly = box[1] - th - 5 if box[1] - th - 5 >= 0 else box[3] + 1
        draw.rectangle((lx, ly, lx + tw + 5, ly + th + 5), fill=color + (255,))
        draw.text((lx + 3, ly + 2), label, fill=text_on(color), font=font)
        drawn += 1

    img.save(out_path)
    return len(elements), drawn


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--result-dir", required=True, help="A bench result dir (holds <stem>.elements.json).")
    ap.add_argument("--image", required=True, help="Source screenshot to draw on.")
    ap.add_argument("--out", default=None, help="Output path (default: <stem>.content.png in the result dir).")
    args = ap.parse_args()

    stem = os.path.splitext(os.path.basename(args.image))[0]
    elements_path = os.path.join(args.result_dir, f"{stem}.elements.json")
    out_path = args.out or os.path.join(args.result_dir, f"{stem}.content.png")
    total, drawn = render(args.image, elements_path, out_path)
    print(f"{stem}: {total} boxes, {drawn} labels -> {out_path}")


if __name__ == "__main__":
    main()

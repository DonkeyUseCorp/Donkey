"""RunPod Serverless handler for Microsoft OmniParser V2.

Wraps OmniParser's screen-parsing pipeline (YOLO icon detection + OCR +
Florence-2 captioning) behind a RunPod serverless endpoint. The handler returns
OmniParser's *raw* output verbatim; downstream callers (e.g. the Donkey site
adapter) own any normalization into product-specific coordinate contracts.

Coordinate note: every `bbox` in `parsed_content_list` is `[x1, y1, x2, y2]`
in ratio space (0-1), independent of image size. `label_coordinates` is
`[x, y, w, h]` in ratio space. See OmniParser util/utils.get_som_labeled_img.
"""

import base64
import io
import os
import sys

import runpod
import torch
from PIL import Image

# OmniParser resolves its weights relative to the working directory, and its
# `util` package is only importable when its repo root is on sys.path. chdir
# alone doesn't add the cwd to sys.path (Python seeds sys.path with the script's
# dir, /app), so do both explicitly before importing from util.
OMNIPARSER_ROOT = "/app/OmniParser"
os.chdir(OMNIPARSER_ROOT)
sys.path.insert(0, OMNIPARSER_ROOT)

from util.utils import (  # noqa: E402  (import after sys.path setup, by design)
    check_ocr_box,
    get_caption_model_processor,
    get_som_labeled_img,
    get_yolo_model,
)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

# Load once at cold start so warm invocations reuse the resident models.
yolo_model = get_yolo_model(model_path="weights/icon_detect/model.pt")
caption_model_processor = get_caption_model_processor(
    model_name="florence2",
    model_name_or_path="weights/icon_caption_florence",
)


def parse_image(image, box_threshold=0.05, iou_threshold=0.1, imgsz=640):
    box_overlay_ratio = image.size[0] / 3200
    draw_bbox_config = {
        "text_scale": 0.8 * box_overlay_ratio,
        "text_thickness": max(int(2 * box_overlay_ratio), 1),
        "text_padding": max(int(3 * box_overlay_ratio), 1),
        "thickness": max(int(3 * box_overlay_ratio), 1),
    }

    ocr_bbox_rslt, _ = check_ocr_box(
        image,
        display_img=False,
        output_bb_format="xyxy",
        goal_filtering=None,
        easyocr_args={"paragraph": False, "text_threshold": 0.9},
        use_paddleocr=False,
    )
    text, ocr_bbox = ocr_bbox_rslt

    labeled_img_b64, label_coordinates, parsed_content_list = get_som_labeled_img(
        image,
        yolo_model,
        BOX_TRESHOLD=box_threshold,
        output_coord_in_ratio=True,
        ocr_bbox=ocr_bbox,
        draw_bbox_config=draw_bbox_config,
        caption_model_processor=caption_model_processor,
        ocr_text=text,
        iou_threshold=iou_threshold,
        imgsz=imgsz,
    )

    return {
        # SOM-annotated PNG (base64). Useful for debugging overlays.
        "labeled_image_base64": labeled_img_b64,
        # Pixel dimensions of the parsed image, so callers can convert the ratio
        # bboxes below into pixel coordinates.
        "image_size": {"width": image.size[0], "height": image.size[1]},
        # {label: [x, y, w, h]} in ratio space.
        "label_coordinates": label_coordinates,
        # [{type, bbox:[x1,y1,x2,y2] ratio, interactivity, content, source?}]
        "parsed_content_list": parsed_content_list,
    }


def handler(event):
    inp = event["input"]
    image_b64 = inp["image"]
    box_threshold = inp.get("box_threshold", 0.05)
    iou_threshold = inp.get("iou_threshold", 0.1)
    imgsz = inp.get("imgsz", 640)

    image_bytes = base64.b64decode(image_b64)
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    return parse_image(
        image,
        box_threshold=box_threshold,
        iou_threshold=iou_threshold,
        imgsz=imgsz,
    )


runpod.serverless.start({"handler": handler})

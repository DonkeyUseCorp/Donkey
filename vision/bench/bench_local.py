#!/usr/bin/env python3
"""In-process OmniParser benchmark on CPU or Apple GPU (MPS), no Docker.

Run vision/bench/setup_local_bench.sh first. This loads the same models the
worker uses and runs the same parse pipeline as handler.py, but lets you put
YOLO + Florence-2 captioning on the Apple GPU (--device mps). OCR (EasyOCR) has
no MPS backend, so it always runs on CPU; that's a small part of the total.

    source vision/bench/.omniparser-local/.venv/bin/activate
    python vision/bench/bench_local.py --image shot.png --device mps
    python vision/bench/bench_local.py --image shot.png --device cpu

Compare the warm numbers here against vision/bench/bench_endpoint.py run against
your RunPod GPU endpoint to decide whether the laptop is fast enough.
"""

import argparse
import os
import pathlib
import statistics
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE / ".omniparser-local"
OMNI = ROOT / "OmniParser"

# EasyOCR's model lookup dir must be set before util.utils imports easyocr
# (it builds a Reader at module load). Point at what setup_local_bench.sh wrote.
os.environ.setdefault("EASYOCR_MODULE_PATH", str(ROOT / ".EasyOCR"))


def load_models(device):
    """Load YOLO + caption models on the requested device.

    Florence-2 is loaded in float32 (via device='cpu') and then moved to MPS.
    OmniParser only switches inputs to float16 when the model is on CUDA, so a
    float32 model on MPS matches its float32 inputs; loading directly with
    device='mps' would give a float16 model and a dtype mismatch at generate().
    """
    from util.utils import get_caption_model_processor, get_yolo_model

    yolo = get_yolo_model(model_path="weights/icon_detect/model.pt")
    caption = get_caption_model_processor(
        model_name="florence2",
        model_name_or_path="weights/icon_caption_florence",
        device="cpu",
    )
    if device != "cpu":
        yolo.to(device)
        caption["model"] = caption["model"].to(device)
    return yolo, caption


def parse_once(image, yolo, caption, box_threshold, iou_threshold, imgsz):
    from util.utils import check_ocr_box, get_som_labeled_img

    box_overlay_ratio = image.size[0] / 3200
    draw_bbox_config = {
        "text_scale": 0.8 * box_overlay_ratio,
        "text_thickness": max(int(2 * box_overlay_ratio), 1),
        "text_padding": max(int(3 * box_overlay_ratio), 1),
        "thickness": max(int(3 * box_overlay_ratio), 1),
    }
    (text, ocr_bbox), _ = check_ocr_box(
        image,
        display_img=False,
        output_bb_format="xyxy",
        goal_filtering=None,
        easyocr_args={"paragraph": False, "text_threshold": 0.9},
        use_paddleocr=False,
    )
    _, _, parsed = get_som_labeled_img(
        image,
        yolo,
        BOX_TRESHOLD=box_threshold,
        output_coord_in_ratio=True,
        ocr_bbox=ocr_bbox,
        draw_bbox_config=draw_bbox_config,
        caption_model_processor=caption,
        ocr_text=text,
        iou_threshold=iou_threshold,
        imgsz=imgsz,
    )
    return parsed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", required=True)
    ap.add_argument("--device", choices=["cpu", "mps"], default="mps")
    ap.add_argument("--runs", type=int, default=4)
    ap.add_argument("--box-threshold", type=float, default=0.05)
    ap.add_argument("--iou-threshold", type=float, default=0.1)
    ap.add_argument("--imgsz", type=int, default=640)
    args = ap.parse_args()

    # Resolve the image to an absolute path before we chdir into OmniParser.
    image_path = pathlib.Path(args.image).resolve()
    if not image_path.exists():
        sys.exit(f"Image not found: {image_path}")

    if not OMNI.exists():
        sys.exit(f"OmniParser not found at {OMNI}. Run: bash {HERE / 'setup_local_bench.sh'}")

    # Let unsupported MPS ops fall back to CPU instead of crashing.
    if args.device == "mps":
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    # util.utils resolves weights relative to cwd and is only importable with
    # the repo root on sys.path (mirrors handler.py).
    os.chdir(OMNI)
    sys.path.insert(0, str(OMNI))

    import torch
    from PIL import Image

    if args.device == "mps" and not torch.backends.mps.is_available():
        sys.exit("MPS not available in this PyTorch build. Try --device cpu.")

    print(f"Device:  {args.device}")
    print(f"Image:   {args.image}")
    print(f"Runs:    {args.runs} (run 1 is cold)\n")

    image = Image.open(image_path).convert("RGB")

    t0 = time.perf_counter()
    yolo, caption = load_models(args.device)
    print(f"  model load: {time.perf_counter() - t0:6.2f}s\n")

    times = []
    for i in range(1, args.runs + 1):
        start = time.perf_counter()
        parsed = parse_once(image, yolo, caption, args.box_threshold, args.iou_threshold, args.imgsz)
        elapsed = time.perf_counter() - start
        label = "cold" if i == 1 else "warm"
        print(f"  run {i} ({label}): {elapsed:6.2f}s  elements={len(parsed)}")
        times.append(elapsed)

    warm = times[1:] or times
    print("\nSummary")
    print(f"  device:       {args.device}")
    print(f"  cold run:     {times[0]:6.2f}s")
    print(f"  warm median:  {statistics.median(warm):6.2f}s")
    print(f"  warm min/max: {min(warm):6.2f}s / {max(warm):6.2f}s")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure OmniParser latency over HTTP against any /runsync endpoint.

Use this to answer "do I need to rent a GPU?" and "where does the latency go?":
run it against the local CPU worker (docker compose up) and against your RunPod
GPU endpoint, then compare the broken-out numbers.

By default the image is compressed exactly the way the Mac app sends it
(downscale to a 896px max dimension, JPEG quality 0.48 — see
apps/.../ScreenshotCompression.swift). The old behaviour of uploading the raw
file is available with --no-compress.

Each run is broken into:
    compress   local downscale + JPEG encode (client CPU)
    queue      RunPod delayTime: dispatch / cold-start wait before the worker runs
    compute    RunPod executionTime: actual work inside the worker (GPU)
    transport  remainder: upload + download + network round trip
    total      end-to-end wall clock the caller feels

Compression needs Pillow, or falls back to macOS `sips` (no install). Timing
breakout needs the endpoint to report delayTime/executionTime (RunPod does;
the local API server may not — those fields show as n/a).

After the runs it saves a results folder under vision/bench/results/
(named <image>-<timestamp>/, override with --out-dir):
    <stem>.elements.json  parsed_content_list + label_coordinates + image_size
    summary.json          timing breakout for every run + warm medians
    summary.txt           the console report, verbatim
Render an overlay from the elements with render_content_overlay.py.
Use --no-save to skip.

Examples:
    # Local CPU worker (docker compose -f vision/docker-compose.yml up)
    python bench_endpoint.py --image shot.png

    # RunPod Cloud GPU endpoint
    python bench_endpoint.py --image shot.png \
        --url https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync \
        --api-key "$RUNPOD_API_KEY"

Only uses the Python standard library (plus optional Pillow / sips for
compression), so it runs with the system python3.
"""

import argparse
import base64
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def compress_image(path, max_dim, jpeg_quality):
    """Downscale to `max_dim` (longest side) and JPEG-encode, mirroring the
    app's ScreenshotCompression (maxPixelDimension=896, jpegQuality=0.48).

    Returns (jpeg_bytes, (width, height), method). Prefers Pillow; falls back
    to macOS `sips` so no install is needed on a Mac.
    """
    quality_pct = max(1, min(100, round(jpeg_quality * 100)))

    try:
        from PIL import Image  # type: ignore
    except ImportError:
        Image = None

    if Image is not None:
        import io

        img = Image.open(path).convert("RGB")
        w, h = img.size
        scale = min(1.0, max_dim / max(w, h))
        if scale < 1.0:
            img = img.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality_pct)
        return buf.getvalue(), img.size, "Pillow"

    # macOS fallback: sips uses the same ImageIO pipeline the app does.
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
        out_path = tf.name
    try:
        subprocess.run(
            ["sips", "-Z", str(max_dim), "-s", "format", "jpeg",
             "-s", "formatOptions", str(quality_pct), path, "--out", out_path],
            check=True, capture_output=True,
        )
        with open(out_path, "rb") as f:
            data = f.read()
        dims = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", out_path],
            check=True, capture_output=True, text=True,
        ).stdout
        w = h = 0
        for line in dims.splitlines():
            line = line.strip()
            if line.startswith("pixelWidth:"):
                w = int(line.split(":")[1])
            elif line.startswith("pixelHeight:"):
                h = int(line.split(":")[1])
        return data, (w, h), "sips"
    except FileNotFoundError:
        raise SystemExit(
            "Compression needs Pillow or macOS `sips`; install Pillow "
            "(pip install pillow) or rerun with --no-compress."
        )
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def save_outputs(output, out_dir, stem):
    """Persist the structured elements JSON for the run.

    The worker also returns a numbered SOM image, but we don't save it — the
    overlay we keep is `<stem>.content.png` from render_content_overlay.py.

    Returns the list of written paths.
    """
    if not isinstance(output, dict):
        return []
    os.makedirs(out_dir, exist_ok=True)
    saved = []

    json_path = os.path.join(out_dir, f"{stem}.elements.json")
    with open(json_path, "w") as f:
        json.dump(
            {
                "image_size": output.get("image_size"),
                "label_coordinates": output.get("label_coordinates"),
                "parsed_content_list": output.get("parsed_content_list"),
            },
            f,
            indent=2,
        )
    saved.append(json_path)
    return saved


def call_once(url, payload, api_key, timeout):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    total = time.perf_counter() - start

    # RunPod (cloud and local API server) wraps handler output under "output"
    # and reports queue/compute timing as top-level ms fields.
    output = body.get("output", body)
    status = body.get("status")
    delay_ms = body.get("delayTime")
    exec_ms = body.get("executionTime")
    queue_s = delay_ms / 1000.0 if isinstance(delay_ms, (int, float)) else None
    compute_s = exec_ms / 1000.0 if isinstance(exec_ms, (int, float)) else None
    transport_s = None
    if queue_s is not None and compute_s is not None:
        transport_s = max(0.0, total - queue_s - compute_s)
    return {
        "total": total,
        "queue": queue_s,
        "compute": compute_s,
        "transport": transport_s,
        "status": status,
        "output": output,
    }


BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_ROOT = os.path.join(BENCH_DIR, "results")


def fmt(value):
    return f"{value:6.2f}s" if isinstance(value, float) else "   n/a"


def median_opt(values):
    present = [v for v in values if isinstance(v, float)]
    return statistics.median(present) if present else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", required=True, help="Path to a PNG/JPEG screenshot.")
    ap.add_argument("--url", default="http://localhost:8000/runsync", help="Full /runsync URL.")
    ap.add_argument("--api-key", default=None, help="Bearer token (RunPod Cloud only).")
    ap.add_argument("--runs", type=int, default=4, help="Total requests (first is the cold run).")
    ap.add_argument("--box-threshold", type=float, default=0.05)
    ap.add_argument("--iou-threshold", type=float, default=0.1)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--timeout", type=float, default=600.0, help="Per-request timeout (s).")
    ap.add_argument("--no-compress", action="store_true",
                    help="Upload the raw file instead of the app-style compressed JPEG.")
    ap.add_argument("--max-dim", type=int, default=896,
                    help="Longest-side pixel cap for compression (app uses 896).")
    ap.add_argument("--jpeg-quality", type=float, default=0.48,
                    help="JPEG quality 0-1 for compression (app uses 0.48).")
    ap.add_argument("--out-dir", default=None,
                    help="Where to save results (default: vision/bench/results/<image>-<timestamp>/).")
    ap.add_argument("--no-save", action="store_true",
                    help="Skip saving the overlay, elements JSON, and summary.")
    args = ap.parse_args()

    raw_bytes = os.path.getsize(args.image)

    # Compress once up front (the app does this per screenshot; we measure it as
    # its own line and reuse the bytes so the per-run compress time is the cost
    # of preparing one screenshot, not re-reading the file each loop).
    if args.no_compress:
        with open(args.image, "rb") as f:
            image_data = f.read()
        compress_s = 0.0
        prep_note = "raw upload (no compression)"
    else:
        t0 = time.perf_counter()
        image_data, dims, method = compress_image(args.image, args.max_dim, args.jpeg_quality)
        compress_s = time.perf_counter() - t0
        prep_note = (
            f"compressed via {method} -> {dims[0]}x{dims[1]} JPEG q{round(args.jpeg_quality * 100)} "
            f"({len(image_data) // 1024} KB, {100 * len(image_data) / raw_bytes:.1f}% of raw)"
        )

    image_b64 = base64.b64encode(image_data).decode("ascii")
    payload = {
        "input": {
            "image": image_b64,
            "box_threshold": args.box_threshold,
            "iou_threshold": args.iou_threshold,
            "imgsz": args.imgsz,
        }
    }

    # Buffer the console report so we can both print it and write it to disk.
    lines = []

    def emit(line=""):
        print(line)
        lines.append(line)

    emit(f"Endpoint: {args.url}")
    emit(f"Image:    {args.image}  (raw {raw_bytes // 1024} KB)")
    emit(f"Payload:  {prep_note}")
    emit(f"          {len(image_b64) // 1024} KB base64 uploaded per run")
    emit(f"Runs:     {args.runs} (run 1 is cold)")
    emit(f"Compress: {compress_s * 1000:.0f} ms (local, once)")
    emit()

    header = f"  {'run':<14} {'total':>7} {'queue':>7} {'compute':>7} {'transport':>10}  status / elements"
    emit(header)
    emit(f"  {'-' * (len(header) - 2)}")

    runs = []
    rows = []
    for i in range(1, args.runs + 1):
        try:
            r = call_once(args.url, payload, args.api_key, args.timeout)
        except urllib.error.URLError as e:
            print(f"  run {i}: request failed: {e}", file=sys.stderr)
            sys.exit(1)
        output = r["output"]
        n_elements = len(output.get("parsed_content_list", [])) if isinstance(output, dict) else 0
        label = "cold" if i == 1 else "warm"
        emit(
            f"  run {i} ({label}){'':<{4 if i < 10 else 3}}"
            f"{fmt(r['total'])} {fmt(r['queue'])} {fmt(r['compute'])} {fmt(r['transport']):>10}"
            f"  {r['status']} / {n_elements} elements"
        )
        runs.append(r)
        rows.append({
            "run": i, "label": label, "total_s": r["total"], "queue_s": r["queue"],
            "compute_s": r["compute"], "transport_s": r["transport"],
            "status": r["status"], "elements": n_elements,
        })

    warm = runs[1:] or runs
    warm_median = {
        "total_s": median_opt([r["total"] for r in warm]),
        "queue_s": median_opt([r["queue"] for r in warm]),
        "compute_s": median_opt([r["compute"] for r in warm]),
        "transport_s": median_opt([r["transport"] for r in warm]),
    }
    emit()
    emit("Summary (warm median)")
    emit(f"  total:      {fmt(warm_median['total_s'])}")
    emit(f"  queue:      {fmt(warm_median['queue_s'])}")
    emit(f"  compute:    {fmt(warm_median['compute_s'])}   <- actual model work")
    emit(f"  transport:  {fmt(warm_median['transport_s'])}   <- upload + download + network")
    emit(f"  compress:   {compress_s * 1000:6.0f} ms  (local, per screenshot)")
    emit()
    emit(f"  cold total: {fmt(runs[0]['total'])}")

    if args.no_save:
        return

    stem = os.path.splitext(os.path.basename(args.image))[0]
    out_dir = args.out_dir or os.path.join(RESULTS_ROOT, f"{stem}-{time.strftime('%Y%m%d-%H%M%S')}")
    os.makedirs(out_dir, exist_ok=True)

    saved = save_outputs(runs[-1]["output"], out_dir, stem)

    summary = {
        "endpoint": args.url,
        "image": os.path.abspath(args.image),
        "raw_kb": raw_bytes // 1024,
        "payload": prep_note,
        "payload_b64_kb": len(image_b64) // 1024,
        "compress_ms": round(compress_s * 1000),
        "runs": rows,
        "warm_median": warm_median,
        "cold_total_s": runs[0]["total"],
    }
    summary_json = os.path.join(out_dir, "summary.json")
    with open(summary_json, "w") as f:
        json.dump(summary, f, indent=2)
    saved.append(summary_json)

    summary_txt = os.path.join(out_dir, "summary.txt")
    with open(summary_txt, "w") as f:
        f.write("\n".join(lines) + "\n")
    saved.append(summary_txt)

    emit()
    emit(f"Saved to {out_dir}")
    for path in saved:
        print(f"  {os.path.basename(path)}")


if __name__ == "__main__":
    main()

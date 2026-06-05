#!/usr/bin/env python3
"""Measure OmniParser latency over HTTP against any /runsync endpoint.

Use this to answer "do I need to rent a GPU?": run it against the local CPU
worker (docker compose up) and against your RunPod GPU endpoint, then compare
the warm-latency numbers.

Examples:
    # Local CPU worker (docker compose -f vision/docker-compose.yml up)
    python bench_endpoint.py --image shot.png

    # RunPod Cloud GPU endpoint
    python bench_endpoint.py --image shot.png \
        --url https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync \
        --api-key "$RUNPOD_API_KEY"

Only uses the Python standard library, so it runs with the system python3.
"""

import argparse
import base64
import json
import statistics
import sys
import time
import urllib.error
import urllib.request


def call_once(url, payload, api_key, timeout):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    elapsed = time.perf_counter() - start
    # RunPod (cloud and local API server) wraps handler output under "output".
    output = body.get("output", body)
    status = body.get("status")
    return elapsed, status, output


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
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        image_b64 = base64.b64encode(f.read()).decode("ascii")

    payload = {
        "input": {
            "image": image_b64,
            "box_threshold": args.box_threshold,
            "iou_threshold": args.iou_threshold,
            "imgsz": args.imgsz,
        }
    }

    print(f"Endpoint: {args.url}")
    print(f"Image:    {args.image}  ({len(image_b64) // 1024} KB base64)")
    print(f"Runs:     {args.runs} (run 1 is cold)\n")

    times = []
    for i in range(1, args.runs + 1):
        try:
            elapsed, status, output = call_once(args.url, payload, args.api_key, args.timeout)
        except urllib.error.URLError as e:
            print(f"  run {i}: request failed: {e}", file=sys.stderr)
            sys.exit(1)
        n_elements = len(output.get("parsed_content_list", [])) if isinstance(output, dict) else 0
        label = "cold" if i == 1 else "warm"
        print(f"  run {i} ({label}): {elapsed:6.2f}s  status={status}  elements={n_elements}")
        times.append(elapsed)

    warm = times[1:] or times
    print("\nSummary")
    print(f"  cold start:   {times[0]:6.2f}s")
    print(f"  warm median:  {statistics.median(warm):6.2f}s")
    print(f"  warm min/max: {min(warm):6.2f}s / {max(warm):6.2f}s")


if __name__ == "__main__":
    main()

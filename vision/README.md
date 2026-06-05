# Vision RunPod Serverless Worker

A [RunPod Serverless](https://docs.runpod.io/serverless/overview) worker that
wraps Microsoft [OmniParser V2](https://github.com/microsoft/OmniParser) — YOLO
icon detection + OCR + Florence-2 captioning — and parses a screenshot into
labeled UI regions.

The worker returns the model's **raw** output. Normalization into Donkey's
screenshot-parser contract lives in the site adapter
(`site/src/lib/inference/screenshot-parsing/vision.ts`), not here. The site
serves it on its own route, `POST /api/inference/vision`, separate from the
gemini-flash parser at `/api/inference/screenshots/parse`.

## Files

| File | Purpose |
| --- | --- |
| `handler.py` | RunPod handler: base64 image in, raw model output out |
| `Dockerfile` | Builds the worker image; bakes V2 weights in at build time |
| `requirements-worker.txt` | Worker-only deps (`runpod`, `huggingface_hub`) |
| `test_input.json` | Sample payload for local handler testing |

## Request / response contract

Request `input`:

```jsonc
{
  "image": "<base64 screenshot, no data: prefix>",
  "box_threshold": 0.05,   // optional
  "iou_threshold": 0.1,    // optional
  "imgsz": 640             // optional
}
```

Response:

```jsonc
{
  "labeled_image_base64": "<base64 PNG with boxes drawn>",
  "label_coordinates": { "0": [x, y, w, h], ... },   // ratio space (0-1)
  "parsed_content_list": [
    {
      "type": "text" | "icon",
      "bbox": [x1, y1, x2, y2],   // ratio space (0-1), NOT pixels
      "interactivity": true,
      "content": "Sign in",
      "source": "box_ocr_content_ocr"   // present for OCR text elements
    }
  ]
}
```

Boxes are image-size-independent ratios. To get Donkey's
`box_2d = [ymin, xmin, ymax, xmax]` in 0-1000 space, multiply by 1000 and
reorder: `[y1*1000, x1*1000, y2*1000, x2*1000]` (the site adapter does this).

## Deploy via RunPod GitHub integration

RunPod builds and hosts the image directly from this repo — no Docker Hub push.

1. RunPod console → **Settings → Connections → GitHub → Connect** and authorize
   access to this repository.
2. **Serverless → New Endpoint → Import Git Repository** → select this repo.
3. Set:
   - **Branch**: `main` (RunPod rebuilds on every push to it)
   - **Dockerfile Path**: `vision/Dockerfile`
4. Pick a GPU (RTX 4090 / A40 / L40S is a good start).
5. **Active workers = 0** for cheap testing (cold starts apply) or `1` for low
   latency. Set sensible execution/idle timeouts.
6. Deploy. Note the **Endpoint ID** — the site adapter needs it.

See RunPod's [GitHub deployment docs](https://docs.runpod.io/serverless/github-integration).

## Local handler test

You don't need a GPU to exercise the handler shape (CPU works, just slow).

```bash
# Put a real screenshot's base64 into test_input.json (replace the placeholder).
base64 -i screenshot.png | tr -d '\n'    # macOS: copy into "image"

# Inside the built image (or a venv with OmniParser + its requirements):
python handler.py            # RunPod SDK auto-runs ./test_input.json
```

Confirm `parsed_content_list` is non-empty and each `bbox` is four values in
0-1. Build the image for local runs with:

```bash
docker build --platform linux/amd64 -t vision-worker:dev vision/
```

## Run it locally (no GPU, for dev and GPU-need evaluation)

The production `Dockerfile` is a CUDA `linux/amd64` image meant for RunPod's
NVIDIA GPUs; on an Apple Silicon Mac it only runs under slow QEMU emulation.
`Dockerfile.local` is a **native arm64, CPU-only** image instead — it builds and
runs natively and serves the same `/runsync` contract over HTTP, so you can wire
the backend against it without renting anything.

> Docker on macOS cannot reach any GPU — not NVIDIA (none present) and not
> Apple's Metal/MPS (invisible to Docker's Linux VM). So this container is
> always CPU. For a GPU number on your laptop, use the MPS benchmark below.

```bash
# Build + start the local worker on :8000 (first build is slow; weights bake in).
docker compose -f vision/docker-compose.yml up --build

# Point the site at it (site/.env.development):
RUNPOD_VISION_BASE_URL="http://localhost:8000"
```

With `RUNPOD_VISION_BASE_URL` set, `POST /api/inference/vision` talks to the
local worker and ignores `RUNPOD_API_KEY` / `RUNPOD_VISION_ENDPOINT_ID`. Unset
it to go back to RunPod Cloud.

## Deciding whether you need a GPU

The cost question comes down to latency: is OmniParser fast enough without a
rented GPU? The benchmark scripts live in `vision/bench/`. Measure all three and
compare warm latency.

```bash
# 1. Local CPU (Docker). Realistic CPU floor.
python vision/bench/bench_endpoint.py --image shot.png

# 2. RunPod Cloud GPU. What you're paying for today.
python vision/bench/bench_endpoint.py --image shot.png \
  --url https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync --api-key "$RUNPOD_API_KEY"

# 3. Apple GPU (MPS), non-Docker — the true "can my laptop replace the GPU?" test.
bash vision/bench/setup_local_bench.sh
source vision/bench/.omniparser-local/.venv/bin/activate
python vision/bench/bench_local.py --image shot.png --device mps
python vision/bench/bench_local.py --image shot.png --device cpu   # comparison
```

Rule of thumb: if MPS warm latency is within your UX budget, you can likely skip
renting GPUs for dev (and possibly light production). If only the rented GPU
hits your budget, the cost is buying that latency.

## Calling the deployed endpoint

```bash
curl -s -X POST \
  "https://api.runpod.ai/v2/${RUNPOD_VISION_ENDPOINT_ID}/runsync" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"input":{"image":"<base64>","box_threshold":0.05,"iou_threshold":0.1,"imgsz":640}}'
```

## Licensing

OmniParser's `icon_detect` (YOLO) weights are **AGPL-3.0**; `icon_caption`
(Florence-2) is **MIT**. This worker bakes both into the image. Keep that in
mind before redistributing the built image — it carries AGPL-3.0 weights.

## Latency note

Serverless inference with zero active workers has real cold-start cost. Treat
it as a fallback/evaluation parser; for low-latency UX run with active
workers ≥ 1 or a persistent pod.

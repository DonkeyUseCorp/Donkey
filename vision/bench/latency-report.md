# Vision parsing: latency & cost notes

How the screenshot parser performs and why it's configured this way. It runs icon
detection, OCR, and captioning on a serverless GPU; the site calls it at
`POST /api/inference/vision`.

```
Client                        Queue                 Worker (GPU)
  |                             |                        |
  |  compress -> 1568px JPEG (~270KB), ~30ms             |
  |                             |                        |
  |--------- upload ----------->|                        |
  |                             |------ dispatch ------->|
  |                             |                        |  parse ~0.2s
  |                             |                        |  (16ms detect + OCR + caps)
  |<-------- elements ----------+------------------------|
  |
  v
  what we control: ~0.2s on the GPU.  upload + queue depend on the connection.
```

## Compress before upload

We downscale each screenshot to 1568px and JPEG-encode it (~270KB) before
sending. This is the biggest win, because the model is fast: ~0.2s to parse, of
which only 16ms is detection. Most of the wait is transferring the image. A raw
screenshot is several megabytes, so the upload and queue dominate — and those
depend on the caller's connection, not us. At ~270KB the upload shrinks
accordingly, with enough detail left to parse.

## Resolution is for detection, not speed

We send 1568px rather than smaller because OCR reads the raw pixels. Below ~900px,
dense screens degrade — a file list blurs and adjacent rows merge into one box. At
1568px they stay separate. The larger image costs a bit more to process, but the
parse stays around 0.2s, so it's worth it.

## Overlap threshold (iou 0.7)

IoU (intersection-over-union) measures how much two boxes overlap: 0 is none, 1 is
identical. After detection, a cleanup pass discards a box when it overlaps a
neighbor by more than this threshold, treating it as a duplicate. At 0.1 it was
too aggressive — boxes that barely touched were removed, so packed elements like
list rows and toolbar icons collapsed into one. At 0.7, only near-identical boxes
merge, and dense neighbors stay separate.

## Endpoint config in code

The scaling settings live in `vision/deploy/endpoint.json` and are pushed to the
live endpoint through the host's API; the image build never reads them.

- **Fast cold-boot (snapshots).** A cold start is ~2s, so scaling up from zero
  workers is cheap.
- **Idle timeout 10s.** A worker is billed while it idles after a request. At 60s
  that idle was most of the cost of a one-off request; 10s brings it to ~$0.003.
- **0 to 5 workers, queue-delay scaling.** Parallelism comes from adding workers
  (one GPU, one request each), not from loading more onto a single GPU.

## Measure compute and transport separately

The bench (`vision/bench/bench_endpoint.py`) splits each run into queue, compute,
and transport using the host's own timings. This keeps the measurements honest: a
worker log reporting "15ms" and a client stopwatch reading several seconds are
both correct — they measure different things. Separating them shows the pipe, not
the model, is the slow part.

## Request timing

Warm, the model parses in ~0.2s and the worker finishes in under a second — that's
the part we control. Upload, queue, and the response depend on the caller's
connection, so total wall-clock varies. The first request after a scale-up is
slower: the model warms up (~0.5s parse) on top of a ~2s boot.

| Stage (what we control) | Warm |
| --- | --- |
| Compress (local) | ~30ms |
| Detection inference | ~16ms |
| Parse (detection + OCR + captions) | ~0.2s |
| Worker execution | ~0.7s |
| Cold boot (snapshot) | ~2s |
| Cost / isolated request | ~$0.003 |
| Upload + queue + response | connection-bound |

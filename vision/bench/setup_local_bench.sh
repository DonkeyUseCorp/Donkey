#!/usr/bin/env bash
# Set up a NON-Docker OmniParser environment on this Mac so bench_local.py can
# run on Apple's GPU (MPS). Docker on macOS can't reach the GPU, so this is the
# only way to measure "can my laptop's GPU replace a rented one?".
#
# Everything lands under vision/bench/.omniparser-local/ (gitignored). Re-running
# is safe; it skips work that's already done. Run from anywhere:
#
#   bash vision/bench/setup_local_bench.sh
#   source vision/bench/.omniparser-local/.venv/bin/activate
#   python vision/bench/bench_local.py --image shot.png --device mps
#
set -euo pipefail

OMNIPARSER_COMMIT="b0d5c9f5701f7e2be4771872e6e928da77759df3"
EASYOCR_MIRROR_REV="17cdb173ef73b32eb6e9d1270f33b30154b03908"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.omniparser-local"
OMNI="$ROOT/OmniParser"
VENV="$ROOT/.venv"
EASYOCR_DIR="$ROOT/.EasyOCR"

mkdir -p "$ROOT"

echo "==> [1/5] Python venv at $VENV"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --quiet --upgrade pip

echo "==> [2/5] Clone OmniParser @ $OMNIPARSER_COMMIT"
if [ ! -d "$OMNI/.git" ]; then
  git clone https://github.com/microsoft/OmniParser.git "$OMNI"
  git -C "$OMNI" checkout "$OMNIPARSER_COMMIT"
fi

echo "==> [3/5] Install deps (torch wheel on macOS includes MPS support)"
# Same curated set as Dockerfile.local; paddle is intentionally omitted.
# transformers pinned to 4.49.0: Florence-2 breaks on 4.50+ (it reads
# config.forced_bos_token_id, removed in 4.50).
pip install --quiet \
  torch torchvision easyocr "supervision==0.18.0" "ultralytics==8.3.70" \
  "transformers==4.49.0" "numpy==1.26.4" opencv-python-headless timm "einops==0.8.0" \
  accelerate "openai==1.3.5" matplotlib pillow huggingface_hub

echo "==> [3b] Stub paddleocr import + construction in util/utils.py"
python - "$OMNI/util/utils.py" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "stubbed: paddle not installed" in s:
    print("    already stubbed"); raise SystemExit
s1 = re.sub(r'from paddleocr import PaddleOCR',
            'PaddleOCR = None  # stubbed: paddle not installed (local mps bench)',
            s, count=1)
s2 = re.sub(r'paddle_ocr = PaddleOCR\(.*?\)', 'paddle_ocr = None', s1, count=1, flags=re.S)
assert s1 != s, "paddle import pattern not found"
assert s2 != s1, "paddle construction pattern not found"
p.write_text(s2)
print("    stubbed OK")
PY

echo "==> [4/5] Download OmniParser V2 weights"
python - "$OMNI" <<'PY'
import sys, shutil, pathlib
from huggingface_hub import hf_hub_download
omni = pathlib.Path(sys.argv[1])
weights = omni / "weights"
files = ["icon_detect/train_args.yaml", "icon_detect/model.pt", "icon_detect/model.yaml",
         "icon_caption/config.json", "icon_caption/generation_config.json", "icon_caption/model.safetensors"]
for f in files:
    if (weights / f).exists():
        continue
    hf_hub_download("microsoft/OmniParser-v2.0", f, local_dir=str(weights))
src, dst = weights / "icon_caption", weights / "icon_caption_florence"
if src.exists() and not dst.exists():
    shutil.move(str(src), str(dst))
print("    weights ready at", weights)
PY

echo "==> [5/5] Download EasyOCR English models"
python - "$EASYOCR_DIR" "$EASYOCR_MIRROR_REV" <<'PY'
import sys, shutil, pathlib
from huggingface_hub import hf_hub_download
out = pathlib.Path(sys.argv[1]) / "model"
rev = sys.argv[2]
out.mkdir(parents=True, exist_ok=True)
for name in ("craft_mlt_25k.pth", "english_g2.pth"):
    if (out / name).exists():
        continue
    path = hf_hub_download("xiaoyao9184/easyocr", name, revision=rev)
    shutil.copy(path, out / name)
print("    easyocr models ready at", out)
PY

echo
echo "Done. Next:"
echo "  source $VENV/bin/activate"
echo "  python $HERE/bench_local.py --image <screenshot.png> --device mps"
echo "  python $HERE/bench_local.py --image <screenshot.png> --device cpu   # for comparison"

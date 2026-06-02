# OmniParser V2 RunPod Serverless worker.
#
# RunPod builds this image from GitHub (Serverless -> Import Git Repository ->
# Dockerfile Path = vision/Dockerfile). The build context is the repo ROOT, not
# vision/, so COPY sources must be repo-relative (e.g. vision/handler.py).
# Build for linux/amd64 if building locally on Apple Silicon, from the repo
# root: docker build --platform linux/amd64 -f vision/Dockerfile .
FROM runpod/pytorch:1.0.3-cu1281-torch260-ubuntu2204

WORKDIR /app

RUN apt-get update && apt-get install -y \
    git \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Pin OmniParser for reproducible builds. Bump deliberately and retest.
ARG OMNIPARSER_COMMIT=b0d5c9f5701f7e2be4771872e6e928da77759df3
RUN git clone https://github.com/microsoft/OmniParser.git \
    && cd OmniParser \
    && git checkout ${OMNIPARSER_COMMIT}

WORKDIR /app/OmniParser

RUN pip install --upgrade pip \
    && pip install --ignore-installed blinker \
    && pip install -r requirements.txt \
    && pip install runpod huggingface_hub \
    # OmniParser leaves transformers unpinned. Florence-2's remote config code
    # reads self.forced_bos_token_id during init; transformers >=4.50 removed
    # that generation attr from PretrainedConfig and raises AttributeError on
    # access (and >=4.52 also breaks Florence-2 on _supports_sdpa), crashing the
    # caption-model load at startup. Pin the last version that loads Florence-2.
    && pip install "transformers==4.49.0"

# OmniParser's util/utils.py builds a PaddleOCR() at import time with kwargs
# (use_gpu, show_log, max_batch_size, use_dilation, det_db_score_mode) that
# only exist in PaddleOCR 2.x; requirements.txt leaves paddleocr unpinned, so
# the build pulls 3.x and the constructor raises ValueError at import, crashing
# the worker. We run EasyOCR (the handler passes use_paddleocr=False) and never
# touch paddle_ocr, so stub the eager construction to None instead of pinning
# the whole paddle stack we don't use. Fails the build loudly if upstream
# changes and the pattern stops matching.
RUN python -c "import re,pathlib,sys; p=pathlib.Path('util/utils.py'); s=p.read_text(); s2=re.sub(r'paddle_ocr = PaddleOCR\(.*?\)','paddle_ocr = None',s,count=1,flags=re.S); p.write_text(s2) if s2!=s else sys.exit('paddle_ocr stub failed: pattern not found in util/utils.py')"

# Bake OmniParser V2 weights into the image so workers don't download on cold
# start. icon_detect (YOLO) weights are AGPL-3.0; icon_caption is MIT.
RUN mkdir -p weights && \
    for f in icon_detect/train_args.yaml icon_detect/model.pt icon_detect/model.yaml \
             icon_caption/config.json icon_caption/generation_config.json icon_caption/model.safetensors; do \
        hf download microsoft/OmniParser-v2.0 "$f" --local-dir weights; \
    done && \
    mv weights/icon_caption weights/icon_caption_florence

# Prefetch EasyOCR's English models (detection + recognition) so the first
# request doesn't pay the ~150MB download. EasyOCR's own downloader pulls from
# github release assets, which the RunPod build sandbox can't reach (it stalled
# builds here for 10min+). HuggingFace IS reachable (the OmniParser weights above
# pull in ~12s), so fetch the byte-identical weights from a mirror, pinned to a
# commit and MD5-verified against JaidedAI's official checksums so a changed or
# corrupt file fails the build loudly. EASYOCR_MODULE_PATH makes the lookup dir
# deterministic at runtime regardless of HOME.
ENV EASYOCR_MODULE_PATH=/root/.EasyOCR
ARG EASYOCR_MIRROR_REV=17cdb173ef73b32eb6e9d1270f33b30154b03908
RUN mkdir -p "$EASYOCR_MODULE_PATH/model" && \
    hf download xiaoyao9184/easyocr craft_mlt_25k.pth --revision "$EASYOCR_MIRROR_REV" --local-dir /tmp/easyocr && \
    hf download xiaoyao9184/easyocr english_g2.pth   --revision "$EASYOCR_MIRROR_REV" --local-dir /tmp/easyocr && \
    cp /tmp/easyocr/craft_mlt_25k.pth /tmp/easyocr/english_g2.pth "$EASYOCR_MODULE_PATH/model/" && \
    echo "2f8227d2def4037cdb3b34389dcf9ec1  $EASYOCR_MODULE_PATH/model/craft_mlt_25k.pth" | md5sum -c && \
    echo "5864788e1821be9e454ec108d61b887d  $EASYOCR_MODULE_PATH/model/english_g2.pth"   | md5sum -c && \
    rm -rf /tmp/easyocr

COPY vision/handler.py /app/handler.py

WORKDIR /app

CMD ["python", "-u", "handler.py"]

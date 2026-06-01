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
    && pip install runpod huggingface_hub

# Bake OmniParser V2 weights into the image so workers don't download on cold
# start. icon_detect (YOLO) weights are AGPL-3.0; icon_caption is MIT.
RUN mkdir -p weights && \
    for f in icon_detect/train_args.yaml icon_detect/model.pt icon_detect/model.yaml \
             icon_caption/config.json icon_caption/generation_config.json icon_caption/model.safetensors; do \
        hf download microsoft/OmniParser-v2.0 "$f" --local-dir weights; \
    done && \
    mv weights/icon_caption weights/icon_caption_florence

# Bake EasyOCR's detection/recognition models into the image too. OmniParser's
# check_ocr_box(use_paddleocr=False) uses EasyOCR, which otherwise downloads
# ~150MB into ~/.EasyOCR on the FIRST request at runtime - so the first parse on
# every fresh worker would hang (and fail outright if the worker has no egress).
# gpu=False just avoids needing a GPU at build time; the cached model files are
# device-agnostic and reused by the runtime Reader.
RUN python -c "import easyocr; easyocr.Reader(['en'], gpu=False)"

COPY vision/handler.py /app/handler.py

WORKDIR /app

CMD ["python", "-u", "handler.py"]

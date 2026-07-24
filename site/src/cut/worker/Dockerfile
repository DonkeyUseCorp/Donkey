# Donkey Cut cloud render worker. Build the bundle first (npm run worker:build),
# then build this image from site/:
#   docker build -f src/cut/worker/Dockerfile -t donkey-cut-worker .
FROM node:22-slim

# ffmpeg/ffprobe for the render pipeline; python3 runs the yt-dlp zipapp.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg python3 ca-certificates curl \
  && curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
       -o /usr/local/bin/yt-dlp \
  && chmod +x /usr/local/bin/yt-dlp \
  && apt-get purge -y curl \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY dist/cut-worker/main.js ./main.js

ENV NODE_ENV=production
ENTRYPOINT ["node", "main.js"]

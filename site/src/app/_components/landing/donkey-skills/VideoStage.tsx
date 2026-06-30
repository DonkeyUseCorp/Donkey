"use client";

import { useEffect, useRef, useState } from "react";

import { cn } from "@/lib/utils";
import { VID_CLIP_END, VID_CLIP_START, VID_CUES, VID_ID, VID_URL } from "./data";
import { CAP, STAGE_WIDE } from "./shared";

// Minimal shape of the YouTube IFrame Player API we depend on.
type YouTubePlayer = {
  playVideo: () => void;
  pauseVideo: () => void;
  getCurrentTime: () => number;
};
type YouTubePlayerCtor = new (
  iframe: HTMLIFrameElement,
  options: { events?: { onReady?: () => void; onStateChange?: (event: { data: number }) => void } },
) => YouTubePlayer;

declare global {
  interface Window {
    YT?: { Player: YouTubePlayerCtor };
    onYouTubeIframeAPIReady?: () => void;
  }
}

// Load the IFrame Player API script once; resolve when the global is ready.
let youTubeApiReady: Promise<void> | null = null;
function loadYouTubeApi(): Promise<void> {
  if (typeof window === "undefined") return Promise.resolve();
  if (window.YT?.Player) return Promise.resolve();
  if (!youTubeApiReady) {
    youTubeApiReady = new Promise((resolve) => {
      const prior = window.onYouTubeIframeAPIReady;
      window.onYouTubeIframeAPIReady = () => {
        prior?.();
        resolve();
      };
      const tag = document.createElement("script");
      tag.src = "https://www.youtube.com/iframe_api";
      document.head.appendChild(tag);
    });
  }
  return youTubeApiReady;
}

const CLIP_SECS = VID_CLIP_END - VID_CLIP_START;
const CLIP_LABEL = `${Math.floor(CLIP_SECS / 60)}:${String(CLIP_SECS % 60).padStart(2, "0")}`;
const CLIP_L = 18;
const CLIP_R = 18;
const EMBED_SRC =
  `https://www.youtube-nocookie.com/embed/${VID_ID}?autoplay=1&start=${VID_CLIP_START}&end=${VID_CLIP_END}` +
  `&controls=0&disablekb=1&modestbranding=1&rel=0&iv_load_policy=3&fs=0&playsinline=1&enablejsapi=1`;

// Clip a YouTube video: an editor preview that plays the real clip on tap. Idle
// shows the trimmed-clip facade; clicking loads the embed and autoplays (the
// click is a user gesture, so playback with sound is allowed). The trim
// playhead is locked to the player's real currentTime via the IFrame API.
export function VideoStage() {
  const [live, setLive] = useState(false);
  const [paused, setPaused] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const playerRef = useRef<YouTubePlayer | null>(null);

  useEffect(() => {
    if (!live) return;
    let cancelled = false;
    let raf = 0;
    const track = () => {
      if (cancelled) return;
      const cur = playerRef.current?.getCurrentTime();
      if (typeof cur === "number" && Number.isFinite(cur)) {
        setElapsed(Math.min(Math.max(cur - VID_CLIP_START, 0), CLIP_SECS));
      }
      raf = requestAnimationFrame(track);
    };
    loadYouTubeApi().then(() => {
      if (cancelled || !iframeRef.current || !window.YT) return;
      playerRef.current = new window.YT.Player(iframeRef.current, {
        events: {
          onReady: () => {
            if (!cancelled) raf = requestAnimationFrame(track);
          },
          // 1 playing · 2 paused · 0 ended.
          onStateChange: (event) => setPaused(event.data === 2 || event.data === 0),
        },
      });
    });
    return () => {
      cancelled = true;
      cancelAnimationFrame(raf);
      playerRef.current = null;
    };
  }, [live]);

  const togglePlay = () => {
    const player = playerRef.current;
    if (!player) return;
    if (paused) player.playVideo();
    else player.pauseVideo();
  };

  const headPct = CLIP_L + (CLIP_SECS ? elapsed / CLIP_SECS : 0) * (100 - CLIP_L - CLIP_R);

  return (
    <div className={STAGE_WIDE}>
      <div className={CAP}>{live ? "Playing the clip…" : "Clip ready · tap to play"}</div>
      <div className="flex flex-col gap-2.5">
        <div className="flex items-center gap-[9px] border-[1.5px] border-ink rounded-[8px] bg-white px-3 py-2 font-code text-xs">
          <span className="flex-none inline-flex items-center justify-center bg-[#C0392B] text-white w-[19px] h-[14px] rounded-[3px] text-[8px]">
            ▶
          </span>
          <span className="text-ink opacity-[0.85] whitespace-nowrap overflow-hidden text-ellipsis">
            {VID_URL}
          </span>
        </div>
        <div
          className={cn(
            "[container-type:size] relative aspect-[16/9] rounded-[8px] overflow-hidden bg-[#15120D] flex items-center justify-center",
            !live && "cursor-pointer",
          )}
          onClick={live ? undefined : () => setLive(true)}
          role={live ? undefined : "button"}
          aria-label={live ? undefined : "Play the clip"}
        >
          {live ? (
            <>
              <iframe
                ref={iframeRef}
                className="absolute inset-0 w-full h-full border-0 pointer-events-none"
                src={EMBED_SRC}
                title="Donkey clip"
                allow="autoplay; encrypted-media; picture-in-picture"
              />
              {/* Transparent layer: swallows hover/clicks so YouTube's title and
                  chrome never surface; tapping toggles play/pause. */}
              <button
                type="button"
                onClick={togglePlay}
                aria-label={paused ? "Play" : "Pause"}
                className="absolute inset-0 z-[5] bg-transparent border-0 cursor-pointer"
              />
              {paused && (
                <div className="relative z-[6] pointer-events-none w-[13cqw] h-[13cqw] rounded-full bg-[rgba(18,15,11,0.62)] border-2 border-white/90 text-white flex items-center justify-center text-[5.4cqw] pl-[1cqw] shadow-[0_2px_12px_rgba(0,0,0,0.5)]">
                  ▶
                </div>
              )}
            </>
          ) : (
            <>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                className="absolute inset-0 w-full h-full object-cover block"
                src={`https://img.youtube.com/vi/${VID_ID}/maxresdefault.jpg`}
                onError={(e) => {
                  const im = e.currentTarget;
                  if (!im.dataset.fb) {
                    im.dataset.fb = "1";
                    im.src = `https://img.youtube.com/vi/${VID_ID}/hqdefault.jpg`;
                  } else {
                    im.style.display = "none";
                  }
                }}
                alt=""
                draggable={false}
              />
              <div className="absolute inset-0 bg-[linear-gradient(180deg,rgba(0,0,0,0.04)_0%,rgba(0,0,0,0.18)_60%,rgba(0,0,0,0.5)_100%)]" />
              <div className="relative z-[4] pointer-events-none w-[13cqw] h-[13cqw] rounded-full bg-[rgba(18,15,11,0.62)] border-2 border-white/90 text-white flex items-center justify-center text-[5.4cqw] pl-[1cqw] shadow-[0_2px_12px_rgba(0,0,0,0.5)]">
                ▶
              </div>
              <div className="absolute z-[3] top-[5%] right-[4%] bg-coral text-ink font-code font-bold text-[2.6cqw] px-2 py-0.5 rounded-[5px]">
                {CLIP_LABEL} clip
              </div>
              <div className="absolute z-[3] left-0 right-0 bottom-[15%] flex flex-col items-center gap-[3px] px-[6%]">
                <div className="text-[3.4cqw] font-semibold text-white bg-[rgba(0,0,0,0.62)] px-[9px] py-0.5 rounded-[4px] text-center animate-[donkey-slide-in_0.25s_ease_both]">
                  {VID_CUES[0].s}
                </div>
              </div>
            </>
          )}
        </div>
        <div className="relative h-7">
          <div className="absolute top-1/2 left-0 right-0 h-1.5 -translate-y-1/2 bg-[#E4DECF] border border-ink rounded-[3px]" />
          <div
            className="absolute top-1/2 h-[15px] -translate-y-1/2 bg-coral border-[1.5px] border-ink rounded-[4px] before:content-[''] before:absolute before:top-1/2 before:-translate-y-1/2 before:w-[3px] before:h-[22px] before:bg-ink before:rounded-[2px] before:left-[-1px] after:content-[''] after:absolute after:top-1/2 after:-translate-y-1/2 after:w-[3px] after:h-[22px] after:bg-ink after:rounded-[2px] after:right-[-1px]"
            style={{ left: `${CLIP_L}%`, right: `${CLIP_R}%` }}
          />
          <div
            className="absolute z-[4] top-1/2 -translate-x-1/2 -translate-y-1/2 w-[3px] h-[26px] bg-ink rounded-[2px] after:content-[''] after:absolute after:left-1/2 after:top-[-6px] after:-translate-x-1/2 after:w-3 after:h-3 after:rounded-full after:bg-ink"
            style={{ left: `${headPct}%` }}
          />
        </div>
      </div>
    </div>
  );
}

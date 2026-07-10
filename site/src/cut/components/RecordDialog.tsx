"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, Square, Video } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { formatTimecode } from "@/cut/lib/time";
import { cn } from "@/lib/utils";

export type RecordMode = "camera" | "audio";

function pickMime(mode: RecordMode) {
  // mp4 first: this Chrome produces empty webm video recordings.
  const candidates =
    mode === "camera"
      ? ["video/mp4", "video/webm;codecs=vp9,opus", "video/webm"]
      : ["audio/mp4", "audio/webm;codecs=opus", "audio/webm"];
  return candidates.find((c) => MediaRecorder.isTypeSupported(c)) ?? "";
}

function stamp() {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getHours())}.${p(d.getMinutes())}.${p(d.getSeconds())}`;
}

type DeviceOption = { id: string; label: string };

// Remembers the last device pick per kind so reopening the dialog restores it.
// Chrome keeps deviceIds stable per-origin once permission is granted.
const STORE_KEY = { videoinput: "cut.record.cameraId", audioinput: "cut.record.micId" };
function loadDeviceId(kind: "videoinput" | "audioinput"): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(STORE_KEY[kind]);
  } catch {
    return null;
  }
}
function saveDeviceId(kind: "videoinput" | "audioinput", id: string | null) {
  try {
    if (id) window.localStorage.setItem(STORE_KEY[kind], id);
    else window.localStorage.removeItem(STORE_KEY[kind]);
  } catch {
    // Ignore storage failures (private mode, quota); the pick just won't persist.
  }
}

function toOptions(devices: MediaDeviceInfo[], kind: MediaDeviceKind, fallback: string) {
  return devices
    .filter((d) => d.kind === kind && d.deviceId)
    .sort((a, b) => Number(b.deviceId === "default") - Number(a.deviceId === "default"))
    .map((d, i) => ({ id: d.deviceId, label: d.label || `${fallback} ${i + 1}` }));
}

export function RecordDialog({
  mode,
  onClose,
  onUse,
}: {
  mode: RecordMode;
  onClose: () => void;
  onUse: (file: File) => void;
}) {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([]);
  // Restore the last pick; null = browser default. The pills show the device
  // the live stream landed on.
  const [cameraId, setCameraId] = useState<string | null>(() => loadDeviceId("videoinput"));
  const [micId, setMicId] = useState<string | null>(() => loadDeviceId("audioinput"));
  const videoRef = useRef<HTMLVideoElement>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const streamRef = useRef<MediaStream | null>(null);

  useEffect(() => {
    let canceled = false;
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    setStream(null);
    const audio: MediaTrackConstraints | boolean = micId
      ? { deviceId: { exact: micId } }
      : true;
    const constraints: MediaStreamConstraints =
      mode === "camera"
        ? {
            video: {
              width: { ideal: 1920 },
              height: { ideal: 1080 },
              ...(cameraId ? { deviceId: { exact: cameraId } } : {}),
            },
            audio,
          }
        : { audio };
    navigator.mediaDevices
      .getUserMedia(constraints)
      .then(async (s) => {
        if (canceled) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = s;
        setStream(s);
        // Device labels are only populated once permission is granted.
        const list = await navigator.mediaDevices.enumerateDevices();
        if (!canceled) setDevices(list);
      })
      .catch(() => {
        if (canceled) return;
        if (cameraId || micId) {
          // The picked device failed to start; fall back to the default and
          // forget it so we don't keep restoring a dead device.
          setCameraId(null);
          setMicId(null);
          saveDeviceId("videoinput", null);
          saveDeviceId("audioinput", null);
          setNotice("That device could not be started — switched back to the default.");
          return;
        }
        setError(
          mode === "camera"
            ? "Camera access was blocked. Allow camera and microphone for this site in Chrome, then try again."
            : "Microphone access was blocked. Allow the microphone for this site in Chrome, then try again."
        );
      });
    return () => {
      canceled = true;
      recorderRef.current?.state === "recording" && recorderRef.current.stop();
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, [mode, cameraId, micId]);

  useEffect(() => {
    const refresh = () =>
      navigator.mediaDevices.enumerateDevices().then(setDevices).catch(() => {});
    navigator.mediaDevices.addEventListener("devicechange", refresh);
    return () => navigator.mediaDevices.removeEventListener("devicechange", refresh);
  }, []);

  useEffect(() => {
    if (stream && videoRef.current) {
      videoRef.current.srcObject = stream;
      void videoRef.current.play().catch(() => {});
    }
  }, [stream]);

  useEffect(() => {
    if (!recording) return;
    const start = Date.now();
    const t = setInterval(() => setElapsed((Date.now() - start) / 1000), 100);
    return () => clearInterval(t);
  }, [recording]);

  const startRecording = () => {
    if (!stream) return;
    const mimeType = pickMime(mode);
    const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    recorderRef.current = recorder;
    chunksRef.current = [];
    recorder.ondataavailable = (e) => {
      if (e.data.size > 0) chunksRef.current.push(e.data);
    };
    recorder.onstop = () => {
      const type = recorder.mimeType || (mode === "camera" ? "video/webm" : "audio/webm");
      const ext = type.includes("mp4") ? (mode === "camera" ? ".mp4" : ".m4a") : ".webm";
      const label = mode === "camera" ? "Camera" : "Voice";
      const file = new File(chunksRef.current, `${label} recording ${stamp()}${ext}`, { type });
      if (file.size === 0) {
        setRecording(false);
        setError("The recording came back empty. Check that no other app is using the camera, then try again.");
        return;
      }
      onUse(file);
      onClose();
    };
    recorder.start(250);
    setElapsed(0);
    setRecording(true);
  };

  const stopRecording = () => {
    setRecording(false);
    recorderRef.current?.stop();
  };

  // Picking a device clears the fallback notice so the live guidance returns —
  // the notice is set once on a device failure and must not outlive the retry.
  const pickCamera = (id: string) => {
    setNotice(null);
    setCameraId(id);
    saveDeviceId("videoinput", id);
  };
  const pickMic = (id: string) => {
    setNotice(null);
    setMicId(id);
    saveDeviceId("audioinput", id);
  };

  const cameras = toOptions(devices, "videoinput", "Camera");
  const mics = toOptions(devices, "audioinput", "Microphone");
  const activeCameraId =
    cameraId ?? stream?.getVideoTracks()[0]?.getSettings().deviceId ?? "";
  const activeMicId =
    micId ?? stream?.getAudioTracks()[0]?.getSettings().deviceId ?? "";

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{mode === "camera" ? "Record camera" : "Record audio"}</DialogTitle>
        </DialogHeader>

        {error ? (
          <p className="text-sm text-muted-foreground">{error}</p>
        ) : (
          <>
            {mode === "camera" ? (
              <div className="relative overflow-hidden rounded-xl bg-black">
                {/* Mirrored preview; the recording itself is not mirrored. */}
                <video
                  ref={videoRef}
                  muted
                  playsInline
                  className="aspect-video w-full -scale-x-100 object-cover"
                />
                {stream && (
                  <LiveWaveform
                    stream={stream}
                    className={cn(
                      "absolute inset-x-0 bottom-11 h-8 text-white/80",
                      recording && "text-red-400"
                    )}
                  />
                )}
                {recording && <RecTimer elapsed={elapsed} />}
                <div className="absolute inset-x-0 bottom-2 flex justify-center gap-2 px-2">
                  <DevicePill
                    icon={<Video className="size-3.5 shrink-0" />}
                    options={cameras}
                    value={activeCameraId}
                    onChange={pickCamera}
                    disabled={recording}
                  />
                  <DevicePill
                    icon={<Mic className="size-3.5 shrink-0" />}
                    options={mics}
                    value={activeMicId}
                    onChange={pickMic}
                    disabled={recording}
                  />
                </div>
              </div>
            ) : (
              <div className="relative grid h-36 place-items-center rounded-xl bg-muted px-4 pb-12">
                {stream ? (
                  <LiveWaveform
                    stream={stream}
                    className={cn("h-16 w-full text-foreground/70", recording && "text-red-500")}
                  />
                ) : (
                  <span className="grid size-16 place-items-center rounded-full bg-card text-foreground shadow-sm">
                    <Mic className="size-7" />
                  </span>
                )}
                {recording && <RecTimer elapsed={elapsed} />}
                <div className="absolute inset-x-0 bottom-2 flex justify-center px-2">
                  <DevicePill
                    icon={<Mic className="size-3.5 shrink-0" />}
                    options={mics}
                    value={activeMicId}
                    onChange={pickMic}
                    disabled={recording}
                  />
                </div>
              </div>
            )}

            <div className="mt-1 flex justify-center">
              {!recording ? (
                <button
                  className="grid size-12 place-items-center rounded-full border-[3px] border-foreground/20 transition-transform hover:scale-105 disabled:opacity-40"
                  title="Start recording"
                  disabled={!stream}
                  onClick={startRecording}
                >
                  <span className="size-8 rounded-full bg-red-500" />
                </button>
              ) : (
                <button
                  className="grid size-12 place-items-center rounded-full border-[3px] border-red-500/40 transition-transform hover:scale-105"
                  title="Stop and use recording"
                  onClick={stopRecording}
                >
                  <Square className="size-5 fill-red-500 stroke-none" />
                </button>
              )}
            </div>
            <p className="text-center text-xs text-muted-foreground">
              {recording
                ? "Recording — click stop to drop it on the timeline."
                : notice ??
                  (stream ? "Click the red button to start." : "Waiting for permission…")}
            </p>
          </>
        )}

        <div className="flex justify-end">
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

/** Meet-style rounded device picker: icon + truncated device name + chevron. */
function DevicePill({
  icon,
  options,
  value,
  onChange,
  disabled,
}: {
  icon: React.ReactNode;
  options: DeviceOption[];
  value: string;
  onChange: (id: string) => void;
  disabled: boolean;
}) {
  if (options.length === 0) return null;
  const items = Object.fromEntries(options.map((o) => [o.id, o.label]));
  return (
    <Select
      value={items[value] ? value : options[0].id}
      items={items}
      onValueChange={(id) => onChange(id as string)}
    >
      <SelectTrigger
        size="sm"
        disabled={disabled}
        className="max-w-[46%] min-w-0 rounded-full border-white/25 bg-black/55 text-xs text-white backdrop-blur-sm hover:bg-black/70 dark:bg-black/55 dark:hover:bg-black/70 [&_svg]:text-white/80"
      >
        {icon}
        <SelectValue className="truncate" />
      </SelectTrigger>
      <SelectContent alignItemWithTrigger={false} className="w-auto max-w-72">
        {options.map((o) => (
          <SelectItem key={o.id} value={o.id} className="text-xs">
            {o.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

// RMS below this reads as silence and draws no bar.
const SILENCE = 0.015;

/** Scrolling level meter fed by the stream's audio track; color follows CSS `color`. */
function LiveWaveform({ stream, className }: { stream: MediaStream; className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  // Bar color follows CSS `color`. Resolve it only when the className changes
  // (i.e. when `recording` toggles) instead of every animation frame.
  const colorRef = useRef("");
  useEffect(() => {
    if (canvasRef.current) colorRef.current = getComputedStyle(canvasRef.current).color;
  }, [className]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || stream.getAudioTracks().length === 0) return;
    const audioCtx = new AudioContext();
    void audioCtx.resume().catch(() => {});
    const source = audioCtx.createMediaStreamSource(stream);
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 1024;
    source.connect(analyser);
    const samples = new Uint8Array(analyser.fftSize);
    const levels: number[] = [];
    let raf = 0;

    const draw = () => {
      raf = requestAnimationFrame(draw);
      analyser.getByteTimeDomainData(samples);
      let sum = 0;
      for (let i = 0; i < samples.length; i++) {
        const v = (samples[i] - 128) / 128;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / samples.length);

      const dpr = window.devicePixelRatio || 1;
      const width = Math.round(canvas.clientWidth * dpr);
      const height = Math.round(canvas.clientHeight * dpr);
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
      const barWidth = 2 * dpr;
      const step = barWidth + 1 * dpr;
      const maxBars = Math.max(1, Math.floor(width / step));
      levels.push(rms);
      if (levels.length > maxBars) levels.splice(0, levels.length - maxBars);

      const g = canvas.getContext("2d");
      if (!g) return;
      g.clearRect(0, 0, width, height);
      g.fillStyle = colorRef.current || getComputedStyle(canvas).color;
      // Interior silence (a pause between two sounds) gets a thin connecting
      // line so the waves read as one continuous track; leading/trailing
      // silence stays empty so the line never dangles into blank space.
      let first = -1;
      let last = -1;
      for (let i = 0; i < levels.length; i++) {
        if (levels[i] >= SILENCE) {
          if (first === -1) first = i;
          last = i;
        }
      }
      const lineH = 2 * dpr;
      for (let i = 0; i < levels.length; i++) {
        const x = width - (levels.length - i) * step;
        if (levels[i] >= SILENCE) {
          const h = Math.max(lineH, Math.min(1, levels[i] * 3) * height);
          g.fillRect(x, (height - h) / 2, barWidth, h);
        } else if (i > first && i < last) {
          // Fill the full step so adjacent segments join into one line.
          g.fillRect(x, (height - lineH) / 2, step, lineH);
        }
      }
    };
    draw();

    return () => {
      cancelAnimationFrame(raf);
      source.disconnect();
      void audioCtx.close().catch(() => {});
    };
  }, [stream]);

  return <canvas ref={canvasRef} className={className} />;
}

function RecTimer({ elapsed }: { elapsed: number }) {
  return (
    <span className="absolute top-2 left-2 flex items-center gap-1.5 rounded-md bg-black/60 px-2 py-1 font-mono text-xs text-white tabular-nums">
      <span className="size-2 animate-pulse rounded-full bg-red-500" />
      {formatTimecode(elapsed)}
    </span>
  );
}

"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, Square } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
  const [recording, setRecording] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const videoRef = useRef<HTMLVideoElement>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const streamRef = useRef<MediaStream | null>(null);

  useEffect(() => {
    let canceled = false;
    navigator.mediaDevices
      .getUserMedia(
        mode === "camera"
          ? { video: { width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: true }
          : { audio: true }
      )
      .then((s) => {
        if (canceled) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = s;
        setStream(s);
      })
      .catch(() =>
        setError(
          mode === "camera"
            ? "Camera access was blocked. Allow camera and microphone for this site in Chrome, then try again."
            : "Microphone access was blocked. Allow the microphone for this site in Chrome, then try again."
        )
      );
    return () => {
      canceled = true;
      recorderRef.current?.state === "recording" && recorderRef.current.stop();
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, [mode]);

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
                {recording && <RecTimer elapsed={elapsed} />}
              </div>
            ) : (
              <div className="relative grid h-36 place-items-center rounded-xl bg-muted">
                <span
                  className={cn(
                    "grid size-16 place-items-center rounded-full bg-card text-foreground shadow-sm",
                    recording && "animate-pulse text-red-500"
                  )}
                >
                  <Mic className="size-7" />
                </span>
                {recording && <RecTimer elapsed={elapsed} />}
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
                : stream
                  ? "Click the red button to start."
                  : "Waiting for permission…"}
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

function RecTimer({ elapsed }: { elapsed: number }) {
  return (
    <span className="absolute top-2 left-2 flex items-center gap-1.5 rounded-md bg-black/60 px-2 py-1 font-mono text-xs text-white tabular-nums">
      <span className="size-2 animate-pulse rounded-full bg-red-500" />
      {formatTimecode(elapsed)}
    </span>
  );
}

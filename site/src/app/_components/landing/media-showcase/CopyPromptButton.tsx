"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Copy } from "lucide-react";

import { cn } from "@/lib/utils";

type Props = {
  className?: string;
  // Label shown in the idle state. Copied state always reads "Copied".
  label?: string;
  text: string;
};

// Copies prompt text to the clipboard and flips to a confirmed state for a
// beat. Shared by the media detail dialog and the use-case detail page.
export function CopyPromptButton({ className, label = "Copy prompt", text }: Props) {
  const [copied, setCopied] = useState(false);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timeoutRef.current) clearTimeout(timeoutRef.current);
    };
  }, []);

  const copy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      return;
    }
    setCopied(true);
    if (timeoutRef.current) clearTimeout(timeoutRef.current);
    timeoutRef.current = setTimeout(() => setCopied(false), 1500);
  }, [text]);

  return (
    <button
      aria-label={copied ? "Prompt copied" : label}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-full border-2 border-ink px-4 py-2 text-[14px] font-semibold transition-colors",
        copied ? "bg-coral text-ink" : "bg-white text-ink hover:bg-cream",
        className,
      )}
      onClick={copy}
      type="button"
    >
      {copied ? <Check size={16} /> : <Copy size={16} />}
      {copied ? "Copied" : label}
    </button>
  );
}

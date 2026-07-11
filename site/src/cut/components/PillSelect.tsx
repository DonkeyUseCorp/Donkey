"use client";

import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";

/** A rounded pill wrapping a native select — a compact `display` shows when closed,
 * while the dropdown lists the fuller option labels (an invisible select overlays the
 * pill, so it keeps native keyboard/OS behavior). Mirrors the audio language picker's
 * chrome so the generate controls read as one family. */
export function PillSelect<T extends string>({
  className,
  title,
  value,
  display,
  options,
  onChange,
}: {
  className?: string;
  title: string;
  value: T;
  display: string;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
}) {
  return (
    <label
      className={cn(
        "relative flex items-center rounded-full border border-input py-1.5 pr-2.5 pl-3.5 transition-colors focus-within:border-ring",
        className
      )}
      title={title}
    >
      <span className="min-w-0 flex-1 truncate text-[12.5px] text-foreground">{display}</span>
      <ChevronDown className="ml-1 size-3.5 shrink-0 text-muted-foreground" />
      <select
        className="absolute inset-0 w-full cursor-pointer appearance-none opacity-0"
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

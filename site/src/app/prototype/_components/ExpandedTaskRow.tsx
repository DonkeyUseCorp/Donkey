import { Play, Square, X } from 'lucide-react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import type { LiveTaskStatus } from '@/app/prototype/_components/types';

type Props = {
  title: string;
  detail: string;
  color: string;
  status: LiveTaskStatus;
  timeText: string;
  onStop: () => void;
  onResume: () => void;
  onClose: () => void;
};

const controlClass =
  'grid h-6 w-6 place-items-center rounded-full bg-white/[0.12] text-white/[0.88] transition hover:bg-white/[0.2]';

export function ExpandedTaskRow({ title, detail, color, status, timeText, onStop, onResume, onClose }: Props) {
  const running = status === 'running';

  return (
    <article className="group relative flex items-start gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-white/[0.07]">
      <DonkeyCursor color={color} size={14} silhouette={!running} className="mt-0.5" />
      <div className="min-w-0 flex-1 pr-[88px]">
        <h2 className="truncate text-[13px] font-normal leading-4 text-white/[0.9]">{title}</h2>
        {detail && (
          <p className="mt-1 line-clamp-5 text-[12px] font-normal leading-[14px] text-white/[0.42]">{detail}</p>
        )}
      </div>

      {/* Controls (fixed top-right): running → stop; stopped → resume + close; done → close. */}
      <div className="absolute right-3 top-2 flex items-center gap-1.5">
        {running && (
          <button type="button" onClick={onStop} aria-label="Stop" className={controlClass}>
            <Square size={9} fill="currentColor" />
          </button>
        )}
        {status === 'stopped' && (
          <button type="button" onClick={onResume} aria-label="Resume" className={controlClass}>
            <Play size={10} fill="currentColor" />
          </button>
        )}
        {!running && (
          <button type="button" onClick={onClose} aria-label="Close" className={controlClass}>
            <X size={11} strokeWidth={2.25} />
          </button>
        )}
      </div>

      {/* Elapsed time is pinned to the bottom-right of the cell so it never moves as the cell grows. */}
      <span className="absolute bottom-2.5 right-3 whitespace-nowrap text-[10px] leading-none text-white/[0.55]">
        {timeText}
      </span>
    </article>
  );
}

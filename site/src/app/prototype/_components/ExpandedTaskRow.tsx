import { MessageSquareReply, Play, Square, X } from 'lucide-react';
import type { MouseEvent } from 'react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import type { LiveTaskStatus } from '@/app/prototype/_components/types';

type Props = {
  title: string;
  detail: string;
  color: string;
  status: LiveTaskStatus;
  timeText: string;
  // Whether this row is the active reply target (full opacity, lit pointer, accent focus).
  isReplyTarget: boolean;
  // Whether another row is the reply target, so this one recedes.
  dimmed: boolean;
  onStop: () => void;
  onResume: () => void;
  onClose: () => void;
  // Begin/toggle reply for this thread — fired by tapping the row and by the Reply button.
  onActivate: () => void;
};

const controlClass =
  'grid h-6 w-6 place-items-center rounded-full bg-white/[0.12] text-white/[0.88] transition hover:bg-white/[0.2]';

export function ExpandedTaskRow({
  title,
  detail,
  color,
  status,
  timeText,
  isReplyTarget,
  dimmed,
  onStop,
  onResume,
  onClose,
  onActivate,
}: Props) {
  const running = status === 'running';
  // The agent is waiting on the user (a clarification/review): it's the only state with a Reply button,
  // and its pointer gently pulses to call attention.
  const waiting = status === 'waiting';
  // Leave room for the pinned controls (a two-button pair when stopped or waiting, else a single
  // button) so the title runs to just left of them; the subtext also clears the bottom-pinned time.
  const controlsReserve = status === 'stopped' || waiting ? 74 : 44;
  const detailReserve = Math.max(controlsReserve, 52);

  // The reply dim is applied per-element so an attention pointer (a waiting thread) can stay lit while
  // the rest of its row recedes. The targeted row's pointer shows its live color even if it had stopped.
  const contentOpacity = dimmed ? 0.5 : 1;
  const pointerOpacity = waiting ? 1 : contentOpacity;
  const pointerActive = running || isReplyTarget;

  // Buttons sit inside the clickable row, so stop their clicks from also activating reply.
  const withStop = (handler: () => void) => (event: MouseEvent) => {
    event.stopPropagation();
    handler();
  };

  return (
    <article
      onClick={withStop(onActivate)}
      className="group relative flex cursor-pointer items-start gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-white/[0.07]"
      style={{ background: isReplyTarget ? 'rgba(255,255,255,0.07)' : undefined }}
    >
      <div
        style={{
          opacity: pointerOpacity,
          animation: waiting ? 'notchArrowPulse 1.6s ease-in-out infinite' : undefined,
        }}
      >
        <DonkeyCursor color={color} size={14} silhouette={!pointerActive} className="mt-0.5" />
      </div>
      <div className="min-w-0 flex-1" style={{ opacity: contentOpacity }}>
        <h2 className="truncate text-[13px] font-normal leading-4 text-white/[0.9]" style={{ paddingRight: controlsReserve }}>
          {title}
        </h2>
        {detail && (
          <p
            className="mt-1 line-clamp-5 text-[12px] font-normal leading-[14px] text-white/[0.42]"
            style={{ paddingRight: detailReserve }}
          >
            {detail}
          </p>
        )}
      </div>

      {/* Controls (fixed top-right): running → stop; stopped → resume + close; waiting → reply + close;
          done / error → close. A finished or failed thread has no button — tap the row to reply. */}
      <div className="absolute right-3 top-2 flex items-center gap-1.5" style={{ opacity: contentOpacity }}>
        {running && (
          <button type="button" onClick={withStop(onStop)} aria-label="Stop" className={controlClass}>
            <Square size={9} fill="currentColor" />
          </button>
        )}
        {status === 'stopped' && (
          <button type="button" onClick={withStop(onResume)} aria-label="Resume" className={controlClass}>
            <Play size={10} fill="currentColor" />
          </button>
        )}
        {waiting && (
          <button type="button" onClick={withStop(onActivate)} aria-label="Reply" className={controlClass}>
            <MessageSquareReply size={12} strokeWidth={2} />
          </button>
        )}
        {!running && (
          <button type="button" onClick={withStop(onClose)} aria-label="Close" className={controlClass}>
            <X size={11} strokeWidth={2.25} />
          </button>
        )}
      </div>

      {/* Elapsed time is pinned to the bottom-right of the cell so it never moves as the cell grows. */}
      <span
        className="absolute bottom-2.5 right-3 whitespace-nowrap text-[10px] leading-none text-white/[0.55]"
        style={{ opacity: contentOpacity }}
      >
        {timeText}
      </span>
    </article>
  );
}

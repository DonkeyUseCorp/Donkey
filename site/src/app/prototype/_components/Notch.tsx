import { ArrowUp, CloudSync, MessageCircleWarning, Shield } from 'lucide-react';
import { type FormEvent, useEffect, useRef, useState } from 'react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import { ExpandedTaskRow } from '@/app/prototype/_components/ExpandedTaskRow';
import type { LiveTask, NotchState, NotchUpdate, NotchVariant } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  variant: NotchVariant;
  updateAvailable: boolean;
  onRestart: () => void;
  missingPermissions: boolean;
  onReviewPermissions: () => void;
  expanded: boolean;
  setExpanded: (expanded: boolean) => void;
  liveTasks: LiveTask[];
  chinUpdate: NotchUpdate | null;
  onAddTask: (title: string) => void;
  onStopTask: (id: string) => void;
  onResumeTask: (id: string) => void;
  onCloseTask: (id: string) => void;
};

const METRICS = {
  collapsedWidth: 253,
  collapsedHeight: 32,
  // The MacBook notch void sits between two 34px content areas (left arrow, right time).
  contentAreaWidth: 34,
  // Chin hangs below the real notch: single streaming line, 9px font, no top padding.
  chinHeight: 20,
  // Simulated notch grows to fit a two-line message inline.
  simulatedMessageHeight: 50,
  expandedWidth: 604,
  expandedHeight: 312,
  expandedContentHeight: 280,
  collapsedCornerRadius: 14,
  simulatedCornerRadius: 16,
  // Spec: the expanded notch window and its input box both use a 14px radius.
  expandedCornerRadius: 14,
  contentInset: 14,
} as const;

// The follow-up input starts as one line and grows with content up to a scroll cap.
const FOLLOWUP_MIN_HEIGHT = 20;
const FOLLOWUP_MAX_HEIGHT = 120;

// Expanded rows have room for the full elapsed time.
function formatRunningTime(totalSeconds: number) {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;

  return `${minutes}m ${seconds}s`;
}

// The collapsed right slot is only 34px wide, so keep elapsed time to ~3 chars: seconds, then minutes, then hours.
function formatCompactTime(totalSeconds: number) {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${seconds}s`;
}

// Running states stream a message into the chin and pulse the arrow.
function isRunningState(state: NotchState) {
  return state === 'running-single' || state === 'running-multi';
}

// Any state other than idle has an active task worth showing run time / a message for.
function hasActiveTask(state: NotchState) {
  return state !== 'idle';
}

export function Notch({
  state,
  variant,
  updateAvailable,
  onRestart,
  missingPermissions,
  onReviewPermissions,
  expanded,
  setExpanded,
  liveTasks,
  chinUpdate,
  onAddTask,
  onStopTask,
  onResumeTask,
  onCloseTask,
}: Props) {
  const isRunning = isRunningState(state);
  const isActive = hasActiveTask(state);
  const isComplete = state === 'complete';
  const needsAttention = state === 'needs-input';
  // The collapsed arrow + chin follow the streaming task update; silhouette when nothing is streaming.
  const streaming = chinUpdate !== null;
  const activeColor = chinUpdate?.color ?? 'rgb(29,158,117)';

  // Collapsed run clock — drives the right-slot elapsed time while a task is active.
  const [runningSeconds, setRunningSeconds] = useState(0);
  const [wasActive, setWasActive] = useState(isActive);
  if (wasActive !== isActive) {
    setWasActive(isActive);
    if (!isActive) setRunningSeconds(0);
  }

  useEffect(() => {
    if (!isRunning) return;

    const interval = window.setInterval(() => setRunningSeconds((seconds) => seconds + 1), 1000);

    return () => window.clearInterval(interval);
  }, [isRunning]);

  // The chin (real) / inline (simulated) shows the current streaming update; hidden when expanded.
  const message = !expanded && chinUpdate ? chinUpdate.message : '';
  const collapsedTime = formatCompactTime(runningSeconds);

  // App-level notices share a single slot; permissions outranks update since it blocks functionality.
  const appNotice: 'permissions' | 'update' | null = missingPermissions
    ? 'permissions'
    : updateAvailable
      ? 'update'
      : null;
  const showChin = variant === 'real' && message !== '';
  const isSimulatedExpandedMessage = variant === 'simulated' && message !== '';

  const collapsedHeight = expanded
    ? METRICS.expandedHeight
    : variant === 'real'
      ? METRICS.collapsedHeight + (showChin ? METRICS.chinHeight : 0)
      : isSimulatedExpandedMessage
        ? METRICS.simulatedMessageHeight
        : METRICS.collapsedHeight;
  const collapsedWidth = expanded ? METRICS.expandedWidth : METRICS.collapsedWidth;

  // Both variants keep a flush top edge (no top corner radius) and round only the bottom.
  const cornerRadius = expanded
    ? METRICS.expandedCornerRadius
    : variant === 'simulated'
      ? METRICS.simulatedCornerRadius
      : METRICS.collapsedCornerRadius;

  // Arrow and run time sit in the real notch's 32px bar, but center in the full simulated pill.
  const contentRowHeight = variant === 'real' ? METRICS.collapsedHeight : collapsedHeight;

  const followUpRef = useRef<HTMLTextAreaElement | null>(null);
  const [canSendFollowUp, setCanSendFollowUp] = useState(false);

  const resizeFollowUp = () => {
    const input = followUpRef.current;
    if (!input) return;

    input.style.height = 'auto';
    input.style.height = `${Math.min(Math.max(input.scrollHeight, FOLLOWUP_MIN_HEIGHT), FOLLOWUP_MAX_HEIGHT)}px`;
    setCanSendFollowUp(input.value.trim().length > 0);
  };

  const handleFollowUpSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const form = event.currentTarget;
    const formData = new FormData(form);
    const taskText = String(formData.get('followUp') ?? '').trim();
    if (!taskText) return;

    onAddTask(taskText);
    form.reset();
    setCanSendFollowUp(false);
    if (followUpRef.current) followUpRef.current.style.height = `${FOLLOWUP_MIN_HEIGHT}px`;
  };

  return (
    <section
      aria-label="Donkey status"
      className="absolute left-1/2 top-0 z-30 -translate-x-1/2 overflow-hidden focus:outline-none"
      style={{
        width: collapsedWidth,
        height: collapsedHeight,
        borderBottomLeftRadius: cornerRadius,
        borderBottomRightRadius: cornerRadius,
        transition: 'width 220ms ease-out, height 220ms ease-out, border-radius 220ms ease-out',
      }}
      tabIndex={0}
      onClick={() => setExpanded(true)}
      onFocus={() => setExpanded(true)}
      onPointerEnter={() => setExpanded(true)}
      onPointerLeave={() => setExpanded(false)}
      onMouseEnter={() => setExpanded(true)}
      onMouseLeave={() => setExpanded(false)}
    >
      <style>{`
        @keyframes notchArrowPulse {
          0%, 100% { transform: scale(1); opacity: 1; }
          50% { transform: scale(1.12); opacity: 0.74; }
        }
      `}</style>
      <div
        className="absolute left-1/2 top-0 overflow-hidden bg-black text-white"
        style={{
          width: collapsedWidth,
          height: collapsedHeight,
          transform: 'translateX(-50%)',
          borderBottomLeftRadius: cornerRadius,
          borderBottomRightRadius: cornerRadius,
          boxShadow: expanded ? '0 12px 24px rgba(0,0,0,0.5)' : '0 0 0 rgba(0,0,0,0)',
          transition:
            'width 550ms cubic-bezier(0.2,0.9,0.24,1), height 550ms cubic-bezier(0.2,0.9,0.24,1), border-radius 550ms cubic-bezier(0.2,0.9,0.24,1), box-shadow 300ms ease-out',
        }}
      >
        <div
          className="absolute inset-0"
          style={{
            opacity: expanded ? 0 : 1,
            transition: 'opacity 150ms ease-out',
            pointerEvents: 'none',
          }}
        >
          {/* Left content area — arrow silhouette when not active; colored, pulsing while running. */}
          <div
            className="absolute left-0 top-0 grid place-items-center"
            style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
          >
            <div style={{ animation: streaming ? 'notchArrowPulse 1.6s ease-in-out infinite' : undefined }}>
              <DonkeyCursor color={activeColor} size={14} silhouette={!streaming} />
            </div>
          </div>

          {/* Right content area — notifications surface here only when needed, otherwise run time. */}
          {needsAttention ? (
            // Chat-bubble alert: the LLM needs the user's attention (e.g. clarification).
            <div
              className="absolute right-0 top-0 grid place-items-center text-white/[0.85]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              <MessageCircleWarning size={15} strokeWidth={1.9} />
            </div>
          ) : isActive ? (
            <div
              className="absolute right-0 top-0 flex flex-col justify-center whitespace-nowrap text-[9px] leading-[11px] text-white/[0.72]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              {isComplete && <span className="text-white/[0.92]">Done</span>}
              <span>{collapsedTime}</span>
            </div>
          ) : appNotice ? (
            // Shield = missing permissions; cloud-sync = app update available (detected on launch).
            <div
              className="absolute right-0 top-0 grid place-items-center text-white/[0.85]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              {appNotice === 'permissions' ? (
                <Shield size={15} strokeWidth={1.9} />
              ) : (
                <CloudSync size={15} strokeWidth={1.9} />
              )}
            </div>
          ) : null}

          {/* Real notch: chin hangs below with the single streaming line (ellipsis if too long). */}
          {variant === 'real' && showChin && (
            <div
              className="absolute left-0 overflow-hidden"
              style={{
                top: METRICS.collapsedHeight,
                width: METRICS.collapsedWidth,
                height: METRICS.chinHeight,
                padding: '0 12px',
              }}
            >
              <p className="truncate text-[9px] leading-[12px] text-white/[0.72]">{message}</p>
            </div>
          )}

          {/* Simulated notch: message sits inline between the arrow and the run time (two lines max). */}
          {variant === 'simulated' && message !== '' && (
            <div
              className="absolute flex items-center"
              style={{
                left: METRICS.contentAreaWidth,
                top: 0,
                width: METRICS.collapsedWidth - METRICS.contentAreaWidth * 2,
                height: collapsedHeight,
              }}
            >
              <p
                className="text-[9px] leading-[12px] text-white/[0.72]"
                style={{
                  display: '-webkit-box',
                  WebkitLineClamp: 2,
                  WebkitBoxOrient: 'vertical',
                  overflow: 'hidden',
                }}
              >
                {message}
              </p>
            </div>
          )}
        </div>

        {/* Expanded right gutter — the only content on the notch row: an app-level action (update / permissions). */}
        {appNotice && (
          <div
            className="absolute right-0 top-0 z-10 flex items-center justify-end gap-2"
            style={{
              height: METRICS.collapsedHeight,
              paddingRight: METRICS.contentInset,
              opacity: expanded ? 1 : 0,
              pointerEvents: expanded ? 'auto' : 'none',
              transition: expanded ? 'opacity 300ms ease-out 150ms' : 'opacity 100ms ease-out',
            }}
          >
            <span className="whitespace-nowrap text-[11px] leading-none text-white/[0.7]">
              {appNotice === 'permissions' ? 'Missing Permissions' : 'Update Available'}
            </span>
            <button
              type="button"
              onClick={appNotice === 'permissions' ? onReviewPermissions : onRestart}
              className="flex items-center rounded bg-white px-2 py-1 text-[11px] font-medium leading-none text-black/[0.82] transition hover:bg-white/[0.92]"
            >
              {appNotice === 'permissions' ? 'Review' : 'Restart'}
            </button>
          </div>
        )}

        <div
          className="absolute left-0 flex flex-col gap-2"
          style={{
            top: METRICS.collapsedHeight,
            width: METRICS.expandedWidth,
            height: METRICS.expandedContentHeight,
            padding: `0 ${METRICS.contentInset}px ${METRICS.contentInset}px`,
            opacity: expanded ? 1 : 0,
            pointerEvents: expanded ? 'auto' : 'none',
            transition: expanded ? 'opacity 300ms ease-out 150ms' : 'opacity 100ms ease-out',
          }}
        >
          {/* Scrollable task list fills the space above the always-visible input. */}
          <div className="min-h-0 flex-1 overflow-y-auto pt-2.5">
            <div className="flex flex-col gap-2">
              {liveTasks.map((task) => (
                <ExpandedTaskRow
                  key={task.id}
                  title={task.title}
                  detail={task.detail}
                  color={task.color}
                  status={task.status}
                  timeText={formatRunningTime(task.seconds)}
                  onStop={() => onStopTask(task.id)}
                  onResume={() => onResumeTask(task.id)}
                  onClose={() => onCloseTask(task.id)}
                />
              ))}
            </div>
          </div>

          {/* Input box is pinned to the bottom and always visible — one line that grows with its text. */}
          <form
            className="relative flex min-h-[56px] w-[576px] shrink-0 items-center rounded-[14px] bg-white/[0.085] px-5 py-3"
            onSubmit={handleFollowUpSubmit}
          >
            <label className="sr-only" htmlFor="donkey-follow-up-input">
              Follow-up
            </label>
            <textarea
              id="donkey-follow-up-input"
              ref={followUpRef}
              name="followUp"
              rows={1}
              placeholder="What can Donkey do for you?"
              onInput={resizeFollowUp}
              className="flex-1 resize-none border-0 bg-transparent p-0 pr-12 text-[16px] font-light leading-[20px] text-white outline-none placeholder:text-white/[0.58]"
              style={{
                height: FOLLOWUP_MIN_HEIGHT,
                maxHeight: FOLLOWUP_MAX_HEIGHT,
                overflowY: 'auto',
                caretColor: 'white',
                fontVariantLigatures: 'none',
              }}
              onKeyDown={(event) => {
                if (event.key === 'Enter' && !event.shiftKey) {
                  event.preventDefault();
                  event.currentTarget.form?.requestSubmit();
                }
              }}
            />
            {/* Send button stays pinned in the lower-right corner, inset from the radius; disabled when empty. */}
            <button
              type="submit"
              disabled={!canSendFollowUp}
              className="absolute bottom-3 right-3 grid h-8 w-8 place-items-center rounded-full transition disabled:cursor-default"
              style={{
                background: canSendFollowUp ? 'rgba(255,255,255,0.9)' : 'rgba(255,255,255,0.32)',
                color: canSendFollowUp ? 'rgba(0,0,0,0.75)' : 'rgba(0,0,0,0.4)',
              }}
              aria-label="Send follow-up"
            >
              <ArrowUp size={16} strokeWidth={2} />
            </button>
          </form>
        </div>
      </div>
    </section>
  );
}

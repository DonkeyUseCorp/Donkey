import { ArrowUp, CloudSync, Coins, MessageCircleWarning, Shield } from 'lucide-react';
import { type FormEvent, type KeyboardEvent, useEffect, useLayoutEffect, useRef, useState } from 'react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import { ExpandedTaskRow } from '@/app/prototype/_components/ExpandedTaskRow';
import { ERROR_RED } from '@/app/prototype/_components/tasks';
import type { LiveTask, NotchState, NotchUpdate, NotchVariant } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  variant: NotchVariant;
  updateAvailable: boolean;
  onRestart: () => void;
  missingPermissions: boolean;
  onReviewPermissions: () => void;
  outOfCredits: boolean;
  onReloadCredits: () => void;
  expanded: boolean;
  setExpanded: (expanded: boolean) => void;
  liveTasks: LiveTask[];
  surfacedTasks: LiveTask[];
  chinUpdate: NotchUpdate | null;
  onAddTask: (title: string) => void;
  onStopTask: (id: string) => void;
  onResumeTask: (id: string) => void;
  onReplyToTask: (id: string, text: string) => void;
  onCloseTask: (id: string) => void;
  loggedOut: boolean;
  onLogin: () => void;
};

const METRICS = {
  collapsedWidth: 253,
  collapsedHeight: 32,
  // The MacBook notch void sits between two 34px content areas (left arrow, right time).
  contentAreaWidth: 34,
  // Chin hangs below the real notch: a 12px streaming line (no top padding) that grows to a second
  // line before truncating. `chinBaseHeight` is one line + the bottom margin; each extra line adds
  // exactly `chinLineHeight`, so the bottom margin stays constant no matter the line count.
  chinBaseHeight: 23,
  chinLineHeight: 15,
  // Surfaced pointers (running + undismissed completions) stack as an overlapping cluster.
  pointerSize: 14,
  pointerStepX: 8,
  pointerStepY: 3,
  maxClusterPointers: 3,
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
  // Logged out: collapsed just shows the "Login to use Donkey" line; expanding reveals a wide bar with
  // the label on the left and the Login button on the right.
  loginCollapsedChinHeight: 22,
  loginExpandedHeight: 84,
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

// The collapsed right slot is only 34px wide, so it shows a single unit — the largest non-zero
// value (hours, else minutes, else seconds). The full elapsed breakdown lives in the expanded row.
function formatCompactTime(totalSeconds: number) {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) return `${hours}h`;
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
  outOfCredits,
  onReloadCredits,
  expanded,
  setExpanded,
  liveTasks,
  surfacedTasks,
  chinUpdate,
  onAddTask,
  onStopTask,
  onResumeTask,
  onReplyToTask,
  onCloseTask,
  loggedOut,
  onLogin,
}: Props) {
  const isRunning = isRunningState(state);
  const isActive = hasActiveTask(state);
  const needsAttention = state === 'needs-input';
  // The collapsed arrow + chin follow the streaming task update; silhouette when nothing is streaming.
  const streaming = chinUpdate !== null;
  const activeColor = chinUpdate?.color ?? 'rgb(29,158,117)';

  // The left content area surfaces a cluster of pointers — running tasks plus completions the user
  // hasn't dismissed yet. One pointer renders alone; several overlap as a centered, cascading stack
  // (newest on top), capped so the notch never crowds. A completed pointer is colored but still.
  // A failed task is a real task, so it keeps its own pointer here (alongside the right-rail warning
  // glyph and held chin); each surfaced task shows a single pointer.
  const clusterTasks = surfacedTasks.slice(0, METRICS.maxClusterPointers);
  const clusterCount = clusterTasks.length;
  const clusterWidth = METRICS.pointerSize + METRICS.pointerStepX * Math.max(0, clusterCount - 1);
  const clusterHeight = METRICS.pointerSize + METRICS.pointerStepY * Math.max(0, clusterCount - 1);

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

  // The chin (real) / inline (simulated) shows the current streaming update; hidden when expanded or
  // once nothing is surfaced, so it never lingers a beat after the last pointer is dismissed.
  const message = !expanded && chinUpdate && surfacedTasks.length > 0 ? chinUpdate.message : '';
  const isErrorChin = chinUpdate?.isError === true;
  const collapsedTime = formatCompactTime(runningSeconds);

  // Measure how many lines the chin message wraps to (capped at two) so the band grows by exactly one
  // line-height for a second line, keeping the bottom margin constant.
  const chinTextRef = useRef<HTMLParagraphElement | null>(null);
  const [chinLines, setChinLines] = useState(1);
  useLayoutEffect(() => {
    const el = chinTextRef.current;
    if (!el) return;
    setChinLines(Math.min(2, Math.max(1, Math.round(el.offsetHeight / METRICS.chinLineHeight))));
  }, [message]);
  const chinHeight = METRICS.chinBaseHeight + (chinLines - 1) * METRICS.chinLineHeight;

  // App-level notices share a single slot. Out of credits outranks everything — nothing can run
  // without a balance; permissions then outranks an update since it blocks functionality.
  const appNotice: 'credits' | 'permissions' | 'update' | null = outOfCredits
    ? 'credits'
    : missingPermissions
      ? 'permissions'
      : updateAvailable
        ? 'update'
        : null;
  // Each notice's collapsed glyph and expanded label + CTA. Out of credits points the user to reload.
  const noticeContent = {
    credits: { Icon: Coins, label: 'Out of Credits', action: 'Reload', onAction: onReloadCredits },
    permissions: { Icon: Shield, label: 'Missing Permissions', action: 'Review', onAction: onReviewPermissions },
    update: { Icon: CloudSync, label: 'Update Available', action: 'Restart', onAction: onRestart },
  } as const;
  const notice = appNotice ? noticeContent[appNotice] : null;
  const showChin = variant === 'real' && message !== '';
  const isSimulatedExpandedMessage = variant === 'simulated' && message !== '';

  const collapsedHeight = expanded
    ? loggedOut
      ? METRICS.loginExpandedHeight
      : METRICS.expandedHeight
    : loggedOut
      ? METRICS.collapsedHeight + METRICS.loginCollapsedChinHeight
      : variant === 'real'
        ? METRICS.collapsedHeight + (showChin ? chinHeight : 0)
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
  const listRef = useRef<HTMLDivElement | null>(null);
  const [canSendFollowUp, setCanSendFollowUp] = useState(false);

  // Reply mode: the thread the user is replying to. Tapping a repliable row (waiting / done / error)
  // pins the next message to it and dims the others; the composer takes that thread's accent color.
  const [replyTargetId, setReplyTargetId] = useState<string | null>(null);
  const replyTarget = replyTargetId ? liveTasks.find((task) => task.id === replyTargetId) ?? null : null;
  // The keyboard highlight: the row the arrows last landed on. It rides on top of the reply focus
  // (brighter fill + ring) and is released as soon as the user starts typing a draft, the same as the
  // app, so the arrows hand back to text editing while the reply stays pinned.
  const [selectedId, setSelectedId] = useState<string | null>(null);

  // Focusing a row is the shared effect of clicking it and of arrowing onto it: it becomes both the
  // keyboard highlight and the pinned reply target (lit pointer, accent composer, dimmed siblings).
  const focusRow = (id: string | null) => {
    setSelectedId(id);
    setReplyTargetId(id);
  };

  // Every thread is repliable by tapping its row, whatever its state. Tapping the active thread again
  // leaves reply mode; tapping any other switches to it. (Only 'waiting' also shows a Reply button,
  // since only there is the agent actively asking.)
  const handleRowActivate = (task: LiveTask) => {
    focusRow(replyTargetId === task.id ? null : task.id);
  };

  // Up/Down move the focus through the rows, landing on each exactly as a click would. The arrows clamp
  // at the ends so the selection is held rather than dropped, and enter the list from the empty composer
  // (Up at the bottom row nearest the input, Down at the top). Escape clears the focus. Once a draft is
  // typed the arrows fall through to edit the text instead (handled by leaving them to the textarea).
  const handleNotchKeyDown = (event: KeyboardEvent) => {
    if (!expanded || loggedOut) return;

    if (event.key === 'Escape') {
      if (selectedId || replyTargetId) {
        event.preventDefault();
        focusRow(null);
      }
      return;
    }

    if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
    if (liveTasks.length === 0) return;

    const currentIndex = selectedId ? liveTasks.findIndex((task) => task.id === selectedId) : -1;
    const draft = followUpRef.current?.value ?? '';
    // No row highlighted and a draft in progress: leave the arrows to the textarea for text editing.
    if (currentIndex === -1 && draft.length > 0) return;

    event.preventDefault();
    const last = liveTasks.length - 1;
    let nextIndex: number;
    if (currentIndex === -1) {
      nextIndex = event.key === 'ArrowUp' ? last : 0;
    } else if (event.key === 'ArrowUp') {
      nextIndex = Math.max(0, currentIndex - 1);
    } else {
      nextIndex = Math.min(last, currentIndex + 1);
    }
    focusRow(liveTasks[nextIndex].id);
  };

  // Focus the composer when a reply begins, so the user can type straight away (no second click).
  useEffect(() => {
    if (replyTargetId) followUpRef.current?.focus();
  }, [replyTargetId]);

  // Keep the keyboard-highlighted row on screen as the arrows walk past the fold.
  useEffect(() => {
    if (!selectedId) return;
    listRef.current?.querySelector(`[data-task-id="${selectedId}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [selectedId]);

  // Collapsing the notch also leaves reply mode, so it never reopens with stale dimming or a highlight.
  const collapse = () => {
    setExpanded(false);
    focusRow(null);
  };

  const resizeFollowUp = () => {
    const input = followUpRef.current;
    if (!input) return;

    input.style.height = 'auto';
    input.style.height = `${Math.min(Math.max(input.scrollHeight, FOLLOWUP_MIN_HEIGHT), FOLLOWUP_MAX_HEIGHT)}px`;
    setCanSendFollowUp(input.value.trim().length > 0);
    // Starting a draft hands the arrows back to the text; the reply stays pinned until sent.
    if (input.value.length > 0) setSelectedId(null);
  };

  const handleFollowUpSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const form = event.currentTarget;
    const formData = new FormData(form);
    const taskText = String(formData.get('followUp') ?? '').trim();
    if (!taskText) return;

    if (replyTargetId) {
      // Replying to a pinned thread continues it with the message rather than starting a new task.
      onReplyToTask(replyTargetId, taskText);
      focusRow(null);
    } else {
      onAddTask(taskText);
      setSelectedId(null);
    }
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
      onKeyDown={handleNotchKeyDown}
      onClick={() => setExpanded(true)}
      onFocus={() => setExpanded(true)}
      onPointerEnter={() => setExpanded(true)}
      onPointerLeave={collapse}
      onMouseEnter={() => setExpanded(true)}
      onMouseLeave={collapse}
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
        {/* Logged out: the notch becomes a login call-to-action instead of the task surface. The
            collapsed chin reads "Login to use Donkey" with a Login button; expanding shows the
            minimal login view. */}
        {loggedOut && (
          <>
            {/* Collapsed: the idle silhouette sits in the left gutter beside the void, and the chin
                below reads "Login to use Donkey" — no button until expanded. */}
            <div
              className="absolute inset-0"
              style={{ opacity: expanded ? 0 : 1, transition: 'opacity 150ms ease-out' }}
            >
              <div
                className="absolute left-0 top-0 grid place-items-center"
                style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
              >
                <DonkeyCursor color={activeColor} size={METRICS.pointerSize} silhouette />
              </div>
              <div
                className="absolute left-0 overflow-hidden"
                style={{
                  top: METRICS.collapsedHeight,
                  width: METRICS.collapsedWidth,
                  height: METRICS.loginCollapsedChinHeight,
                  padding: '0 12px',
                }}
              >
                <p className="truncate text-[12px] leading-[15px] text-white/[0.82]">Login to use Donkey</p>
              </div>
            </div>

            {/* Expanded: a wide bar — the label on the left, the Login button on the right. */}
            <div
              className="absolute left-0 flex items-center justify-between"
              style={{
                top: METRICS.collapsedHeight,
                width: METRICS.expandedWidth,
                height: METRICS.loginExpandedHeight - METRICS.collapsedHeight,
                padding: `0 ${METRICS.contentInset + 4}px`,
                opacity: expanded ? 1 : 0,
                pointerEvents: expanded ? 'auto' : 'none',
                transition: expanded ? 'opacity 300ms ease-out 150ms' : 'opacity 100ms ease-out',
              }}
            >
              <span className="text-[16px] leading-none text-white/[0.92]">Login to use Donkey</span>
              <button
                type="button"
                onClick={(event) => {
                  event.stopPropagation();
                  onLogin();
                }}
                className="flex items-center rounded-lg bg-white px-5 py-2 text-[14px] font-medium leading-none text-black/[0.82] transition hover:bg-white/[0.92]"
              >
                Login
              </button>
            </div>
          </>
        )}

        {!loggedOut && (
          <>
        <div
          className="absolute inset-0"
          style={{
            opacity: expanded ? 0 : 1,
            transition: 'opacity 150ms ease-out',
            pointerEvents: 'none',
          }}
        >
          {/* Left content area — a silhouette when nothing is surfaced, otherwise the pointer cluster
              centered in the lane: one colored pointer, or an overlapping stack for several tasks. */}
          <div
            className="absolute left-0 top-0"
            style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
          >
            {clusterCount === 0 ? (
              <div className="grid h-full w-full place-items-center">
                <DonkeyCursor color={activeColor} size={METRICS.pointerSize} silhouette />
              </div>
            ) : (
              <div
                style={{
                  position: 'absolute',
                  left: (METRICS.contentAreaWidth - clusterWidth) / 2,
                  top: (contentRowHeight - clusterHeight) / 2,
                  width: clusterWidth,
                  height: clusterHeight,
                }}
              >
                {/* Oldest first so the newest pointer lands on top, furthest along the cascade. */}
                {[...clusterTasks].reverse().map((task, index) => (
                  <div
                    key={task.id}
                    style={{
                      position: 'absolute',
                      left: index * METRICS.pointerStepX,
                      top: index * METRICS.pointerStepY,
                      zIndex: index,
                      animation: task.status === 'running' ? 'notchArrowPulse 1.6s ease-in-out infinite' : undefined,
                    }}
                  >
                    <DonkeyCursor color={task.color} size={METRICS.pointerSize} />
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Right content area — notifications surface here only when needed, otherwise run time. */}
          {isErrorChin && message !== '' ? (
            // Error (e.g. an auth failure): the warning glyph rides the right rail in error red while
            // the message holds the chin, until the user expands to acknowledge it.
            <div
              className="absolute right-0 top-0 grid place-items-center"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              <MessageCircleWarning size={15} strokeWidth={1.9} color={ERROR_RED} />
            </div>
          ) : needsAttention ? (
            // Chat-bubble alert: the LLM needs the user's attention (e.g. clarification).
            <div
              className="absolute right-0 top-0 grid place-items-center text-white/[0.85]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              <MessageCircleWarning size={15} strokeWidth={1.9} />
            </div>
          ) : isRunning && streaming ? (
            // Live run time only rides alongside the chin narration; without a chin the gutter stays empty.
            <div
              className="absolute right-0 top-0 grid place-items-center whitespace-nowrap text-[11px] leading-none text-white/[0.72]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              {collapsedTime}
            </div>
          ) : notice ? (
            // Coins = out of credits; shield = missing permissions; cloud-sync = app update available.
            <div
              className="absolute right-0 top-0 grid place-items-center text-white/[0.85]"
              style={{ width: METRICS.contentAreaWidth, height: contentRowHeight }}
            >
              <notice.Icon size={15} strokeWidth={1.9} />
            </div>
          ) : null}

          {/* Real notch: chin hangs below with the streaming line, growing to two lines before it
              truncates with an ellipsis. An error holds the chin; its warning icon rides the right rail. */}
          {variant === 'real' && showChin && (
            <div
              className="absolute left-0 overflow-hidden"
              style={{
                top: METRICS.collapsedHeight,
                width: METRICS.collapsedWidth,
                height: chinHeight,
                padding: '0 12px',
              }}
            >
              <p
                ref={chinTextRef}
                className="text-[12px] leading-[15px] text-white/[0.72]"
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

          {/* Simulated notch: message sits inline between the arrow and the run time (two lines max);
              an error's warning icon rides the right rail, matching the real notch. */}
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
                className="text-[12px] leading-[15px] text-white/[0.72]"
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

        {/* Expanded right gutter — the only content on the notch row: an app-level action (reload
            credits / review permissions / restart to update). */}
        {notice && (
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
            <span className="whitespace-nowrap text-[11px] leading-none text-white/[0.7]">{notice.label}</span>
            <button
              type="button"
              onClick={notice.onAction}
              className="flex items-center rounded bg-white px-2 py-1 text-[11px] font-medium leading-none text-black/[0.82] transition hover:bg-white/[0.92]"
            >
              {notice.action}
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
          // Tapping bare chrome (not a row or the composer, which stop propagation) leaves reply mode.
          onClick={() => {
            if (replyTargetId || selectedId) focusRow(null);
          }}
        >
          {/* Scrollable task list fills the space above the always-visible input. */}
          <div ref={listRef} className="min-h-0 flex-1 overflow-y-auto pt-2.5">
            <div className="flex flex-col gap-2">
              {liveTasks.map((task) => (
                <ExpandedTaskRow
                  key={task.id}
                  taskId={task.id}
                  title={task.title}
                  detail={task.detail}
                  color={task.color}
                  status={task.status}
                  timeText={formatRunningTime(task.seconds)}
                  isReplyTarget={replyTargetId === task.id}
                  isSelected={selectedId === task.id}
                  dimmed={replyTargetId !== null && replyTargetId !== task.id}
                  onStop={() => onStopTask(task.id)}
                  onResume={() => onResumeTask(task.id)}
                  onClose={() => {
                    if (replyTargetId === task.id || selectedId === task.id) focusRow(null);
                    onCloseTask(task.id);
                  }}
                  onActivate={() => handleRowActivate(task)}
                />
              ))}
            </div>
          </div>

          {/* Input box is pinned to the bottom and always visible — one line that grows with its text.
              While replying it's outlined in the targeted thread's accent color. */}
          <form
            className="relative flex min-h-[40px] w-[576px] shrink-0 items-center rounded-[14px] bg-white/[0.085] px-5 py-1.5"
            style={{
              boxShadow: replyTarget ? `inset 0 0 0 1.5px ${replyTarget.color}` : undefined,
              transition: 'box-shadow 160ms ease-out',
            }}
            onClick={(event) => event.stopPropagation()}
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
              className="flex-1 resize-none border-0 bg-transparent p-0 pr-11 text-[16px] font-light leading-[20px] text-white outline-none placeholder:text-white/[0.58]"
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
              className="absolute bottom-1.5 right-1.5 grid h-7 w-7 place-items-center rounded-full transition disabled:cursor-default"
              style={{
                background: canSendFollowUp ? 'rgba(255,255,255,0.9)' : 'rgba(255,255,255,0.32)',
                color: canSendFollowUp ? 'rgba(0,0,0,0.75)' : 'rgba(0,0,0,0.4)',
              }}
              aria-label="Send follow-up"
            >
              <ArrowUp size={15} strokeWidth={2} />
            </button>
          </form>
        </div>
          </>
        )}
      </div>
    </section>
  );
}

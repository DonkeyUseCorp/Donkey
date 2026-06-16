import { ArrowUp, Check, MessageCircle, Pause, Play } from 'lucide-react';
import type { FormEvent } from 'react';

import { ActivityBars } from '@/app/prototype/_components/ActivityBars';
import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import { TASKS } from '@/app/prototype/_components/tasks';
import type { NotchState, Spawn, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  activeTaskId: TaskId;
  expanded: boolean;
  setExpanded: (expanded: boolean) => void;
  spawnCue: Spawn | null;
  onRequestSpawn: (taskText: string) => void;
};

const METRICS = {
  collapsedWidth: 248,
  collapsedHeight: 32,
  expandedWidth: 604,
  expandedHeight: 312,
  expandedContentHeight: 280,
  collapsedCornerRadius: 14,
  expandedCornerRadius: 26,
  contentInset: 14,
} as const;

type RowStatus = 'running' | 'completed' | 'needsAttention';

type TaskRow = {
  id: string;
  title: string;
  detail: string;
  color: string;
  status: RowStatus;
};

function taskRowsForState(state: NotchState, activeTaskId: TaskId): TaskRow[] {
  const activeTask = TASKS[activeTaskId];
  const activeTitle = activeTask.label;

  if (state === 'idle') {
    return [];
  }

  if (state === 'running-multi') {
    return [
      { id: 'compare', title: TASKS.compare.label, detail: 'Running', color: TASKS.compare.color, status: 'running' },
      { id: 'research', title: TASKS.research.label, detail: 'Running', color: TASKS.research.color, status: 'running' },
      { id: 'schedule', title: TASKS.schedule.label, detail: 'Running', color: TASKS.schedule.color, status: 'running' },
    ];
  }

  if (state === 'complete') {
    return [
      { id: activeTask.id, title: activeTitle, detail: 'Done', color: activeTask.color, status: 'completed' },
      { id: 'weather', title: "Find tomorrow's weather", detail: 'Done', color: TASKS.schedule.color, status: 'completed' },
    ];
  }

  if (state === 'needs-input') {
    return [
      { id: activeTask.id, title: activeTitle, detail: 'Needs attention', color: activeTask.color, status: 'needsAttention' },
      { id: 'weather', title: "Find tomorrow's weather", detail: 'Done', color: TASKS.schedule.color, status: 'completed' },
    ];
  }

  return [
    { id: activeTask.id, title: activeTitle, detail: 'Running', color: activeTask.color, status: 'running' },
    { id: 'weather', title: "Find tomorrow's weather", detail: 'Done', color: TASKS.schedule.color, status: 'completed' },
  ];
}

function spawnCueExitTransform(angleDegrees: number) {
  const radians = (angleDegrees * Math.PI) / 180;
  const distance = 28;

  return {
    x: Math.cos(radians) * distance,
    y: Math.sin(radians) * distance,
  };
}

export function Notch({ state, activeTaskId, expanded, setExpanded, spawnCue, onRequestSpawn }: Props) {
  const rows = taskRowsForState(state, activeTaskId);
  const activeColor = rows[0]?.color ?? 'rgb(29,158,117)';
  const spawnCueOffset = spawnCue ? spawnCueExitTransform(spawnCue.notchCueAngleDegrees) : null;

  const handleFollowUpSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const form = event.currentTarget;
    const formData = new FormData(form);
    const taskText = String(formData.get('followUp') ?? '').trim();
    if (!taskText) return;

    onRequestSpawn(taskText);
    form.reset();
  };

  const spawnCueArrow = spawnCue && spawnCueOffset && (
    <>
      <style>{`
        @keyframes notchSpawnCue-${spawnCue.id} {
          0%, 30% {
            transform: translate(-50%, -50%) rotate(-45deg);
            opacity: 1;
          }
          100% {
            transform: translate(calc(-50% + ${spawnCueOffset.x}px), calc(-50% + ${spawnCueOffset.y}px)) rotate(${spawnCue.notchCueAngleDegrees}deg);
            opacity: 0;
          }
        }
      `}</style>
      <div
        className="absolute z-10"
        style={{
          left: 17,
          top: Math.max(14, METRICS.collapsedHeight / 2),
          width: 15,
          height: 15,
          animation: `notchSpawnCue-${spawnCue.id} 260ms ease-in-out both`,
        }}
        aria-hidden="true"
      >
        <DonkeyCursor color={spawnCue.color} size={15} />
      </div>
    </>
  );

  return (
    <section
      aria-label="Donkey status"
      className="absolute left-1/2 top-0 z-30 -translate-x-1/2 overflow-hidden focus:outline-none"
      style={{
        width: expanded ? METRICS.expandedWidth : METRICS.collapsedWidth,
        height: expanded ? METRICS.expandedHeight : METRICS.collapsedHeight,
        borderBottomLeftRadius: expanded ? METRICS.expandedCornerRadius : METRICS.collapsedCornerRadius,
        borderBottomRightRadius: expanded ? METRICS.expandedCornerRadius : METRICS.collapsedCornerRadius,
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
      <div
        className="absolute left-1/2 top-0 overflow-hidden bg-black text-white"
        style={{
          width: expanded ? METRICS.expandedWidth : METRICS.collapsedWidth,
          height: expanded ? METRICS.expandedHeight : METRICS.collapsedHeight,
          transform: 'translateX(-50%)',
          borderBottomLeftRadius: expanded ? METRICS.expandedCornerRadius : METRICS.collapsedCornerRadius,
          borderBottomRightRadius: expanded ? METRICS.expandedCornerRadius : METRICS.collapsedCornerRadius,
          boxShadow: expanded ? '0 12px 24px rgba(0,0,0,0.5)' : '0 0 0 rgba(0,0,0,0)',
          transition:
            'width 550ms cubic-bezier(0.2,0.9,0.24,1), height 550ms cubic-bezier(0.2,0.9,0.24,1), border-radius 550ms cubic-bezier(0.2,0.9,0.24,1), box-shadow 300ms ease-out',
        }}
      >
        <div
          className="absolute inset-0"
          style={{
            opacity: expanded || spawnCue ? 0 : 1,
            transition: 'opacity 150ms ease-out',
            pointerEvents: 'none',
          }}
        >
          <DonkeyCursor color={activeColor} size={13} className="absolute left-[10.5px] top-[9.5px]" />
        </div>

        {spawnCueArrow}

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
          {rows.length > 0 && (
            <div className="min-h-0 flex-1 overflow-hidden pt-2.5">
              <div className="flex flex-col gap-2">
                {rows.map((task) => (
                  <article
                    key={task.id}
                    className="flex h-12 items-center gap-3 rounded-lg bg-white/[0.055] px-3"
                  >
                    <DonkeyCursor color={task.color} size={14} />
                    <div className="min-w-0 flex-1">
                      <h2 className="truncate text-[13px] font-normal leading-4 text-white/[0.9]">{task.title}</h2>
                      <p className="mt-1 truncate text-[12px] font-normal leading-[14px] text-white/[0.42]">
                        {task.detail}
                      </p>
                    </div>
                    {task.status === 'running' ? (
                      <div className="flex gap-1.5">
                        <button
                          type="button"
                          className="grid h-6 w-6 place-items-center rounded-full bg-white/[0.055] text-white/[0.3]"
                          aria-label="Resume"
                          disabled
                        >
                          <Play size={10} fill="currentColor" />
                        </button>
                        <button
                          type="button"
                          className="grid h-6 w-6 place-items-center rounded-full bg-white/[0.12] text-white/[0.88]"
                          aria-label="Pause"
                        >
                          <Pause size={10} fill="currentColor" />
                        </button>
                      </div>
                    ) : task.status === 'completed' ? (
                      <Check size={18} color={task.color} strokeWidth={1.35} />
                    ) : task.status === 'needsAttention' ? (
                      <MessageCircle size={18} color={task.color} strokeWidth={1.35} />
                    ) : (
                      <ActivityBars color={task.color} />
                    )}
                  </article>
                ))}
              </div>
            </div>
          )}

          <form
            className="relative h-[92px] w-[576px] rounded-[22px] bg-white/[0.085]"
            style={{ marginTop: rows.length === 0 ? 16 : 0 }}
            onSubmit={handleFollowUpSubmit}
          >
            <label className="sr-only" htmlFor="donkey-follow-up-input">
              Follow-up
            </label>
            <textarea
              id="donkey-follow-up-input"
              name="followUp"
              rows={1}
              placeholder="What can donkey do for you?"
              className="absolute left-6 top-3 h-[19.2px] w-[528px] resize-none overflow-hidden border-0 bg-transparent p-0 text-[16px] font-light leading-[19.2px] text-white outline-none placeholder:text-white/[0.58]"
              style={{ caretColor: 'white', fontVariantLigatures: 'none' }}
              onKeyDown={(event) => {
                if (event.key === 'Enter' && !event.shiftKey) {
                  event.preventDefault();
                  event.currentTarget.form?.requestSubmit();
                }
              }}
            />
            <button
              type="submit"
              className="absolute bottom-4 right-4 grid h-8 w-8 place-items-center rounded-full bg-white/[0.9] text-black/[0.75]"
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

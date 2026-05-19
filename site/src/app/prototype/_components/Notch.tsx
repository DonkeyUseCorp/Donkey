import { MousePointer2, Plus, Sparkles } from 'lucide-react';

import { ActivityBars } from '@/app/prototype/_components/ActivityBars';
import { TaskArrow } from '@/app/prototype/_components/TaskArrow';
import { ALL_TASK_IDS, TASKS } from '@/app/prototype/_components/tasks';
import type { NotchState, SetHovering, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  activeTaskId: TaskId;
  hovering: boolean;
  setHovering: SetHovering;
  runningTaskIds: TaskId[];
};

const NOTCH = {
  restWidth: 110,
  restHeight: 28,
  cornerRadius: 14,
  expandedWidth: 480,
  expandedHeight: 280,
  expandedRadius: 26,
} as const;

const EASE = 'cubic-bezier(0.22, 1, 0.36, 1)';
const DURATION = '0.55s';

export function Notch({ state, activeTaskId, hovering, setHovering, runningTaskIds }: Props) {
  const activeTask = TASKS[activeTaskId];
  const isExpanded = hovering || state === 'expanded-pinned';
  const surfaceWidth = isExpanded ? NOTCH.expandedWidth : NOTCH.restWidth;
  const surfaceHeight = isExpanded ? NOTCH.expandedHeight : NOTCH.restHeight;
  const surfaceRadius = isExpanded ? NOTCH.expandedRadius : NOTCH.cornerRadius;

  return (
    <div
      className="absolute top-0 left-1/2 -translate-x-1/2 z-20"
      style={{
        width: isExpanded ? `${NOTCH.expandedWidth + 40}px` : `${NOTCH.restWidth + 60}px`,
        height: isExpanded ? `${NOTCH.expandedHeight + 20}px` : `${NOTCH.restHeight + 20}px`,
        transition: `width ${DURATION} ${EASE}, height ${DURATION} ${EASE}`,
      }}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
    >
      <div
        className="absolute top-0 left-1/2 overflow-hidden bg-black text-white"
        style={{
          width: `${surfaceWidth}px`,
          height: `${surfaceHeight}px`,
          transform: 'translateX(-50%)',
          borderTopLeftRadius: 0,
          borderTopRightRadius: 0,
          borderBottomLeftRadius: `${surfaceRadius}px`,
          borderBottomRightRadius: `${surfaceRadius}px`,
          boxShadow: isExpanded
            ? '0 24px 48px -12px rgba(0,0,0,0.5), 0 8px 16px -8px rgba(0,0,0,0.3)'
            : 'none',
          outline: '1px dashed rgba(255,36,148,0.95)',
          outlineOffset: '-1px',
          transition: [
            `width ${DURATION} ${EASE}`,
            `height ${DURATION} ${EASE}`,
            `border-radius ${DURATION} ${EASE}`,
            `box-shadow ${DURATION} ${EASE}`,
          ].join(', '),
          zIndex: 30,
        }}
      >
        <div
          className="absolute inset-0 flex items-center pl-3.5 pr-3.5"
          style={{
            opacity: isExpanded ? 0 : 1,
            transition: `opacity 0.15s ${EASE}`,
            pointerEvents: 'none',
          }}
        >
          <MousePointer2
            size={14}
            color="#fff"
            fill="#fff"
            strokeWidth={0}
            style={{ transform: 'rotate(-8deg)' }}
          />
        </div>

        <div
          className="absolute inset-0 flex flex-col"
          style={{
            opacity: isExpanded ? 1 : 0,
            padding: 18,
            pointerEvents: isExpanded ? 'auto' : 'none',
            transition: isExpanded ? `opacity 0.3s ${EASE} 0.15s` : `opacity 0.1s ${EASE}`,
          }}
        >
          <div className="flex items-center gap-2 border-b border-white/10 pb-2.5">
            <TaskArrow color={activeTask.color} size={14} className="-rotate-45" />
            <span className="text-[12px] text-white/95">Donkey</span>
            <span className="text-[11px] text-white/45 ml-0.5">
              {state === 'idle' ? 'ready' : activeTask.label.toLowerCase()}
            </span>
            <div className="ml-auto flex items-center gap-1 text-[10px] text-white/45 hover:text-white/80 cursor-pointer">
              <Plus size={11} />
              <span>new task</span>
            </div>
          </div>

          <div className="grid grid-cols-5 gap-2 py-3">
            {ALL_TASK_IDS.map((id) => {
              const task = TASKS[id];
              const isRunning = runningTaskIds.includes(id);
              const isActiveStateTask = activeTaskId === id && (state === 'complete' || state === 'needs-input');
              let statusLabel = isRunning ? 'running' : 'idle';
              let statusColor = isRunning ? task.color : 'rgba(255,255,255,0.4)';
              if (isActiveStateTask && state === 'complete') statusLabel = 'done';
              if (isActiveStateTask && state === 'needs-input') {
                statusLabel = 'needs you';
                statusColor = task.color;
              }

              return (
                <div
                  key={id}
                  className="flex min-w-0 flex-col items-center gap-1.5 rounded-md border border-white/[0.06] bg-white/[0.04] px-1 py-2 transition hover:-translate-y-px hover:bg-white/[0.07]"
                  style={isRunning ? { background: `${task.color}1A` } : undefined}
                >
                  <div
                    className="flex h-6 w-6 items-center justify-center rounded-md"
                    style={{ background: task.color }}
                  >
                    <TaskArrow color="#fff" size={13} className="-rotate-45" />
                  </div>
                  <span className="max-w-full truncate text-[10px] text-white/75">{task.label.split(' ')[0]}</span>
                  <span
                    className="max-w-full truncate rounded px-1 py-px text-[8px]"
                    style={{
                      background: `${statusColor}30`,
                      color: statusColor === 'rgba(255,255,255,0.4)' ? 'rgba(255,255,255,0.5)' : statusColor,
                    }}
                  >
                    {statusLabel}
                  </span>
                </div>
              );
            })}
          </div>

          <div className="mt-auto flex items-center gap-2 rounded-md border border-white/[0.08] bg-white/[0.06] px-3 py-2.5">
            <Sparkles size={12} color="rgba(255,255,255,0.45)" />
            <span className="min-w-0 flex-1 truncate text-[12px] text-white/40">Tell Donkey what to do...</span>
            {state !== 'idle' && <ActivityBars color={activeTask.color} />}
          </div>
        </div>
      </div>
    </div>
  );
}

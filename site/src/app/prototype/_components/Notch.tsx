import { Plus, Sparkles, Check } from 'lucide-react';
import type { CSSProperties } from 'react';

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

type RingStyle = CSSProperties & {
  '--ring'?: string;
};

export function Notch({ state, activeTaskId, hovering, setHovering, runningTaskIds }: Props) {
  const activeTask = TASKS[activeTaskId];
  const isExpanded = hovering || state === 'expanded-pinned';
  const expandedWidth = 440;
  const expandedHeight = 286;
  const prototypeNotchWidth = 180;
  const restingArrowAllowance = 34;
  const restingSurfaceWidth = prototypeNotchWidth + restingArrowAllowance * 2;
  const restingSurfaceLeft = (expandedWidth - prototypeNotchWidth) / 2 - restingArrowAllowance;

  const isComplete = state === 'complete';
  const isAttention = state === 'needs-input';
  const isMulti = state === 'running-multi';
  const isHero = isComplete || isAttention;
  const isResting = state === 'idle';

  let collapsedWidthStyle: CSSProperties;
  if (isResting) collapsedWidthStyle = { width: `${restingSurfaceWidth}px` };
  else if (isHero) collapsedWidthStyle = { width: '360px' };
  else if (isMulti) collapsedWidthStyle = { width: '220px' };
  else if (state === 'running-single') collapsedWidthStyle = { width: 'fit-content', minWidth: '200px', maxWidth: '420px' };
  else collapsedWidthStyle = { width: '200px' };

  const ringColor = isComplete
    ? 'rgba(29,158,117,0.55)'
    : isAttention
    ? 'rgba(212,83,126,0.65)'
    : 'transparent';

  const collapsedBodyStyle: RingStyle = {
    ...collapsedWidthStyle,
    margin: isResting ? `0 0 0 ${restingSurfaceLeft}px` : '0 auto',
    borderRadius: isResting ? '0 0 9px 9px' : isHero ? '0 0 22px 22px' : '0 0 14px 14px',
    boxShadow: !isExpanded && ringColor !== 'transparent' ? `0 0 0 1.5px ${ringColor}` : 'none',
    outline: '1px dashed rgba(255,36,148,0.95)',
    outlineOffset: '2px',
    opacity: isExpanded ? 0 : 1,
    transition: 'opacity 0.12s ease, border-radius 0.24s cubic-bezier(0.32, 0.72, 0, 1), box-shadow 0.3s ease',
    '--ring': ringColor,
  };

  return (
    <div
      className="absolute top-0 left-1/2 -translate-x-1/2 z-20"
      style={{
        width: `${expandedWidth}px`,
        height: isExpanded ? `${expandedHeight}px` : undefined,
      }}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
    >
      <style>{`
        @keyframes pulseRing {
          0%,100% { box-shadow: 0 0 0 1.5px var(--ring), 0 0 0 0 rgba(212,83,126,0); }
          50% { box-shadow: 0 0 0 1.5px var(--ring), 0 0 0 6px rgba(212,83,126,0.15); }
        }
        @keyframes fadeinUp {
          from { opacity: 0; transform: translateY(-4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .pulse-attention { animation: pulseRing 1.6s ease-in-out infinite; }
        .fadein-up { animation: fadeinUp 0.3s cubic-bezier(0.32, 0.72, 0, 1) both; }
      `}</style>
      <div
        className={`relative bg-black text-white overflow-hidden ${isAttention && !isExpanded ? 'pulse-attention' : ''}`}
        style={collapsedBodyStyle}
      >
        {!isExpanded && state === 'idle' && (
          <div className="flex h-[18px] items-center pl-2.5">
            <TaskArrow color={activeTask.color} size={13} />
          </div>
        )}

        {!isExpanded && state === 'running-single' && (
          <div className="flex items-center justify-center gap-2 pl-3.5 pr-4 py-1.5">
            <div
              className="w-3.5 h-3.5 rounded-full flex items-center justify-center flex-shrink-0"
              style={{ background: 'transparent' }}
            >
              <TaskArrow color={activeTask.color} size={12} />
            </div>
            <span className="text-[10px] tracking-tight whitespace-nowrap text-white/95">
              {`Donkey · ${activeTask.label.toLowerCase()}`}
            </span>
            <ActivityBars color={activeTask.color} />
          </div>
        )}

        {!isExpanded && isMulti && (
          <div className="flex items-center justify-center gap-2 px-3 py-1.5">
            <div className="flex items-center">
              {runningTaskIds.slice(0, 4).map((id, i) => (
                <div
                  key={id}
                  className="w-3 h-3 rounded-full"
                  style={{
                    background: TASKS[id].color,
                    border: '1.5px solid #000',
                    marginLeft: i === 0 ? 0 : '-4px',
                    zIndex: 10 - i,
                  }}
                />
              ))}
            </div>
            <span className="text-[10px] text-white/95 whitespace-nowrap">
              Donkey gets things done
            </span>
            <ActivityBars color="rgba(255,255,255,0.85)" />
          </div>
        )}

        {!isExpanded && isComplete && (
          <div className="flex items-center gap-2.5 px-4 pt-1.5 pb-2.5 fadein-up">
            <div className="relative flex-shrink-0">
              <div className="w-7 h-7 rounded-md flex items-center justify-center">
                <TaskArrow color={activeTask.color} size={20} />
              </div>
              <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-white flex items-center justify-center">
                <Check size={8} color={activeTask.color} strokeWidth={3} />
              </div>
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-1.5">
                <span className="text-[11px]">Donkey finished</span>
                <span className="text-[9px] text-white/50">· 1m 42s</span>
              </div>
              <div className="text-[10px] text-white/65 truncate">{activeTask.label}</div>
            </div>
            <button
              type="button"
              className="text-[10px] px-2 py-1 rounded"
              style={{ background: `${activeTask.color}66`, color: '#fff' }}
            >
              View
            </button>
          </div>
        )}

        {!isExpanded && isAttention && (
          <div className="flex items-center gap-2.5 px-4 pt-1.5 pb-2.5 fadein-up">
            <div className="relative flex-shrink-0">
              <div className="w-7 h-7 rounded-md flex items-center justify-center">
                <TaskArrow color={activeTask.color} size={20} />
              </div>
              <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-white flex items-center justify-center">
                <span style={{ fontSize: '9px', color: activeTask.color, lineHeight: 1 }}>!</span>
              </div>
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-1.5">
                <span className="text-[11px]">Donkey needs you</span>
                <span className="text-[9px] text-white/50">· paused</span>
              </div>
              <div className="text-[10px] text-white/65 truncate">Pick a source for the search</div>
            </div>
            <button
              type="button"
              className="text-[10px] px-2 py-1 rounded"
              style={{ background: `${activeTask.color}80`, color: '#fff' }}
            >
              Answer
            </button>
          </div>
        )}
      </div>

      <div
        className="absolute left-0 top-0 w-full overflow-hidden"
        style={{
          height: `${expandedHeight}px`,
          pointerEvents: isExpanded ? 'auto' : 'none',
        }}
      >
        <div
          className="bg-black text-white overflow-hidden"
          style={{
            width: '100%',
            height: '100%',
            borderRadius: '0 0 22px 22px',
            outline: '1px dashed rgba(255,36,148,0.95)',
            outlineOffset: '-1px',
            transform: isExpanded ? 'translateY(0)' : 'translateY(-100%)',
            transition: 'transform 0.34s cubic-bezier(0.32, 0.72, 0, 1)',
          }}
        >
          <div className="px-3.5 pt-2 pb-2 flex items-center gap-2 border-b border-white/10">
            <TaskArrow color={activeTask.color} size={14} />
            <span className="text-[11px]">Donkey</span>
            <span className="text-[10px] text-white/45 ml-1">gets things done</span>
            <div className="ml-auto flex items-center gap-1 text-[10px] text-white/45 hover:text-white/80 cursor-pointer">
              <Plus size={11} />
              <span>new task</span>
            </div>
          </div>

          <div className="p-2 flex flex-col gap-1">
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
                  className="flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-white/5 cursor-pointer"
                  style={isRunning ? { background: `${task.color}1A`, borderLeft: `2px solid ${task.color}` } : {}}
                >
                  <div className="w-5 h-5 flex items-center justify-center flex-shrink-0">
                    <TaskArrow color={task.color} size={16} />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5">
                      <span className="text-[10px]">{task.label}</span>
                      <span
                        className="text-[9px] px-1 py-px rounded"
                        style={{
                          background: `${statusColor}30`,
                          color: statusColor === 'rgba(255,255,255,0.4)' ? 'rgba(255,255,255,0.5)' : statusColor,
                        }}
                      >
                        {statusLabel}
                      </span>
                    </div>
                    <div className="text-[9px] text-white/50 truncate">{isRunning ? task.detail : 'Ready when needed'}</div>
                  </div>
                  {isRunning ? (
                    <ActivityBars color={task.color} />
                  ) : (
                    <span className="h-1.5 w-1.5 rounded-full bg-white/30" />
                  )}
                </div>
              );
            })}
          </div>

          <div className="mx-2 mb-2 px-2.5 py-2 bg-white/[0.06] rounded-md flex items-center gap-2">
            <Sparkles size={11} color="rgba(255,255,255,0.5)" />
            <span className="text-[10px] text-white/40 flex-1">Tell Donkey what to do…</span>
          </div>
        </div>
      </div>
    </div>
  );
}

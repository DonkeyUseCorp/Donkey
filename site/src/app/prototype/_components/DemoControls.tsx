import { Check, Trash2 } from 'lucide-react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import { ALL_TASK_IDS, TASKS } from '@/app/prototype/_components/tasks';
import type { NotchState, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  setState: (state: NotchState) => void;
  activeTaskId: TaskId;
  setActiveTaskId: (id: TaskId) => void;
  spawnCount: number;
  onClearSpawns: () => void;
};

type StateOption = {
  id: NotchState;
  label: string;
};

const STATE_OPTIONS: StateOption[] = [
  { id: 'idle', label: 'Idle' },
  { id: 'running-single', label: 'Run' },
  { id: 'running-multi', label: 'Busy' },
  { id: 'complete', label: 'Done' },
  { id: 'needs-input', label: 'Ask' },
  { id: 'expanded-pinned', label: 'Open' },
];

export function DemoControls({
  state,
  setState,
  activeTaskId,
  setActiveTaskId,
  spawnCount,
  onClearSpawns,
}: Props) {
  return (
    <aside
      aria-label="Prototype controls"
      className="fixed bottom-5 left-1/2 z-50 flex max-w-[calc(100vw-40px)] -translate-x-1/2 items-center gap-3 rounded-xl border border-white/10 bg-black/70 px-3 py-2 text-white shadow-2xl backdrop-blur-xl"
    >
      <div className="flex items-center gap-1.5">
        {STATE_OPTIONS.map((option) => {
          const active = state === option.id;

          return (
            <button
              key={option.id}
              type="button"
              onClick={() => setState(option.id)}
              className="h-8 rounded-lg px-2.5 text-[11px] font-medium transition"
              style={{
                background: active ? 'rgba(255,255,255,0.92)' : 'rgba(255,255,255,0.08)',
                color: active ? 'rgba(0,0,0,0.82)' : 'rgba(255,255,255,0.72)',
              }}
            >
              {option.label}
            </button>
          );
        })}
      </div>

      <div className="h-7 w-px bg-white/10" />

      <div className="flex items-center gap-1.5">
        {ALL_TASK_IDS.map((id) => {
          const task = TASKS[id];
          const active = activeTaskId === id;

          return (
            <button
              key={id}
              type="button"
              onClick={() => setActiveTaskId(id)}
              className="grid h-8 w-8 place-items-center rounded-lg transition"
              style={{
                background: active ? `${task.color}33` : 'rgba(255,255,255,0.08)',
                boxShadow: active ? `inset 0 0 0 1px ${task.color}` : 'inset 0 0 0 1px transparent',
              }}
              aria-label={task.label}
            >
              {active ? <Check size={14} color={task.color} /> : <DonkeyCursor color={task.color} size={15} />}
            </button>
          );
        })}
      </div>

      {spawnCount > 0 && (
        <>
          <div className="h-7 w-px bg-white/10" />
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              onClick={onClearSpawns}
              className="inline-flex h-8 items-center gap-1.5 rounded-lg bg-white/[0.08] px-2 text-[11px] font-medium text-white/[0.72] transition hover:bg-white/[0.14]"
            >
              <Trash2 size={12} />
              {spawnCount}
            </button>
          </div>
        </>
      )}
    </aside>
  );
}

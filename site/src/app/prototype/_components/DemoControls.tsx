import { Check } from 'lucide-react';

import { ControlButton } from '@/app/prototype/_components/ControlButton';
import { TaskArrow } from '@/app/prototype/_components/TaskArrow';
import { ALL_TASK_IDS, TASKS } from '@/app/prototype/_components/tasks';
import type { NotchState, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  setState: (state: NotchState) => void;
  activeTaskId: TaskId;
  setActiveTaskId: (id: TaskId) => void;
};

type StateOption = {
  id: NotchState;
  label: string;
  desc: string;
  accent?: string;
};

export function DemoControls({ state, setState, activeTaskId, setActiveTaskId }: Props) {
  const stateOptions: StateOption[] = [
    { id: 'idle', label: 'Idle', desc: 'Nothing running' },
    { id: 'running-single', label: 'Running', desc: 'One task active', accent: TASKS[activeTaskId].color },
    { id: 'running-multi', label: 'Busy', desc: '3 tasks in motion' },
    { id: 'complete', label: 'Task complete', desc: 'Bulge + check', accent: TASKS[activeTaskId].color },
    { id: 'needs-input', label: 'Needs your input', desc: 'Pulsing · persistent', accent: TASKS[activeTaskId].color },
    { id: 'expanded-pinned', label: 'Expanded (pinned)', desc: 'Force-open the panel' },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <div className="bg-white rounded-xl border p-5" style={{ borderColor: '#e5e3dc' }}>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="font-medium text-[15px]">Notch state</h2>
            <p className="text-xs text-gray-500 mt-0.5">Click to switch states</p>
          </div>
          <div className="font-mono text-[10px] text-gray-400 uppercase tracking-wider">{state}</div>
        </div>
        <div className="grid grid-cols-2 gap-2">
          {stateOptions.map((opt) => (
            <ControlButton key={opt.id} active={state === opt.id} onClick={() => setState(opt.id)} accent={opt.accent}>
              <div className="font-medium text-[13px]">{opt.label}</div>
              <div className="text-[11px] opacity-60 mt-0.5">{opt.desc}</div>
            </ControlButton>
          ))}
        </div>
      </div>

      <div className="bg-white rounded-xl border p-5" style={{ borderColor: '#e5e3dc' }}>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="font-medium text-[15px]">Sample task</h2>
            <p className="text-xs text-gray-500 mt-0.5">Drives the color & message</p>
          </div>
          <div className="font-mono text-[10px] text-gray-400 uppercase tracking-wider">{activeTaskId}</div>
        </div>
        <div className="grid grid-cols-1 gap-1.5">
          {ALL_TASK_IDS.map((id) => {
            const task = TASKS[id];
            const isSelected = activeTaskId === id;
            return (
              <button
                type="button"
                key={id}
                onClick={() => setActiveTaskId(id)}
                className="px-2.5 py-2 rounded-lg flex items-center gap-2.5 transition-all border"
                style={{
                  background: isSelected ? '#fafaf6' : '#fff',
                  borderColor: isSelected ? task.color : '#e5e3dc',
                }}
              >
                <div className="w-6 h-6 flex items-center justify-center flex-shrink-0">
                  <TaskArrow color={task.color} size={18} />
                </div>
                <div className="flex-1 text-left min-w-0">
                  <div className="text-[12px] font-medium">{task.label}</div>
                  <div className="text-[10px] text-gray-500 truncate">{task.detail}</div>
                </div>
                {isSelected && <Check size={14} color={task.color} />}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

import { Apple, Wifi, BatteryFull } from 'lucide-react';

import { Notch } from '@/app/prototype/_components/Notch';
import { SpawnedCursor } from '@/app/prototype/_components/SpawnedCursor';
import { SpawnInputOverlay } from '@/app/prototype/_components/SpawnInputOverlay';
import { TaskArrow } from '@/app/prototype/_components/TaskArrow';
import { ALL_TASK_IDS, TASKS } from '@/app/prototype/_components/tasks';
import type { DesktopRef, DesktopSize, NotchState, SetHovering, Spawn, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  activeTaskId: TaskId;
  runningTaskIds: TaskId[];
  hovering: boolean;
  setHovering: SetHovering;
  spawns: Spawn[];
  onRequestSpawn: (taskText: string) => void;
  spawnInputOpen: boolean;
  onCloseSpawnInput: () => void;
  desktopRef: DesktopRef;
  desktopSize: DesktopSize;
};

export function MacDesktop({
  state,
  activeTaskId,
  runningTaskIds,
  hovering,
  setHovering,
  spawns,
  onRequestSpawn,
  spawnInputOpen,
  onCloseSpawnInput,
  desktopRef,
  desktopSize,
}: Props) {
  const isExpanded = hovering || state === 'expanded-pinned';
  const notchAnchor = { x: desktopSize.w / 2, y: 24 };

  return (
    <div ref={desktopRef} className="relative w-full overflow-hidden rounded-2xl border border-black/10" style={{ aspectRatio: '16 / 10' }}>
      <div
        className="absolute inset-0"
        style={{
          backgroundImage:
            'radial-gradient(circle at 20% 30%, rgba(120,100,200,0.25) 0%, transparent 50%), radial-gradient(circle at 80% 70%, rgba(80,140,200,0.2) 0%, transparent 50%), linear-gradient(180deg, #2d2a4a 0%, #1a1d29 100%)',
        }}
      />

      <div
        className="absolute top-0 left-0 right-0 h-7 flex items-center px-4 gap-4 text-[11px] text-white/85"
        style={{ background: 'rgba(20,22,30,0.5)', backdropFilter: 'blur(10px)' }}
      >
        <Apple size={13} fill="currentColor" />
        <span className="font-medium">Finder</span>
        <span>File</span>
        <span>Edit</span>
        <span>View</span>
        <span>Go</span>
        <span>Window</span>
        <span>Help</span>
        <div className="ml-auto flex items-center gap-3.5">
          <Wifi size={13} />
          <BatteryFull size={13} />
          <span>Sun 5:02 PM</span>
        </div>
      </div>

      {isExpanded && <div className="absolute inset-0 bg-black/40 z-10 transition-opacity duration-300" />}

      <Notch state={state} activeTaskId={activeTaskId} hovering={hovering} setHovering={setHovering} runningTaskIds={runningTaskIds} />

      {spawns.map((s) => (
        <SpawnedCursor key={s.id} spawn={s} notchAnchor={notchAnchor} />
      ))}

      {spawnInputOpen && <SpawnInputOverlay onSubmit={onRequestSpawn} onClose={onCloseSpawnInput} />}

      <div
        className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-2xl px-3 py-1.5 flex gap-2 transition-opacity duration-300"
        style={{
          background: 'rgba(255,255,255,0.15)',
          border: '0.5px solid rgba(255,255,255,0.25)',
          backdropFilter: 'blur(20px) saturate(180%)',
          opacity: isExpanded ? 0.5 : 1,
        }}
      >
        {ALL_TASK_IDS.map((id) => {
          const task = TASKS[id];
          const isRunning = runningTaskIds.includes(id);
          return (
            <div key={id} className="relative">
              <div className="w-8 h-8 flex items-center justify-center">
                <TaskArrow color={task.color} size={22} />
              </div>
              {isRunning && <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1 h-1 rounded-full bg-white" />}
            </div>
          );
        })}
      </div>
    </div>
  );
}

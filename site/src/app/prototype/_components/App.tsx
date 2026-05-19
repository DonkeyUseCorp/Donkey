'use client';

import { useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Plus } from 'lucide-react';

import { DemoControls } from '@/app/prototype/_components/DemoControls';
import { MacDesktop } from '@/app/prototype/_components/MacDesktop';
import { TASK_COLORS } from '@/app/prototype/_components/tasks';
import type { DesktopSize, NotchState, Spawn, SpawnPhase, TaskId } from '@/app/prototype/_components/types';

let spawnCounter = 0;

export default function App() {
  const [state, setState] = useState<NotchState>('running-single');
  const [activeTaskId, setActiveTaskId] = useState<TaskId>('compare');
  const [hovering, setHovering] = useState(false);
  const [spawns, setSpawns] = useState<Spawn[]>([]);
  const [spawnInputOpen, setSpawnInputOpen] = useState(false);
  const desktopRef = useRef<HTMLDivElement | null>(null);
  const [desktopSize, setDesktopSize] = useState<DesktopSize>({ w: 1000, h: 625 });
  const runningTaskIds = useMemo<TaskId[]>(() => {
    if (state === 'idle') return [];
    if (state === 'running-multi') return ['compare', 'research', 'schedule'];

    return [activeTaskId];
  }, [state, activeTaskId]);

  useLayoutEffect(() => {
    if (!desktopRef.current) return;
    const ro = new ResizeObserver((entries) => {
      const r = entries[0].contentRect;
      setDesktopSize({ w: r.width, h: r.height });
    });
    ro.observe(desktopRef.current);
    return () => ro.disconnect();
  }, []);

  const advanceSpawn = (id: string, nextPhase: SpawnPhase) => {
    setSpawns((curr) => curr.map((s) => (s.id === id ? { ...s, phase: nextPhase } : s)));
  };

  const handleSpawn = (taskText: string) => {
    const id = `spawn-${++spawnCounter}-${Date.now()}`;
    const color = TASK_COLORS[spawnCounter % TASK_COLORS.length];
    const label = taskText.slice(0, 40);
    const padding = 60;
    const target = {
      x: padding + Math.random() * (desktopSize.w - padding * 2),
      y: 90 + Math.random() * (desktopSize.h - 160),
    };
    const curveSide = Math.random() > 0.5 ? 1 : -1;

    setSpawns((curr) => [...curr, { id, color, label, target, phase: 'emerge', curveSide, startedAt: Date.now() }]);
    setSpawnInputOpen(false);

    setTimeout(() => advanceSpawn(id, 'travel'), 500);
    setTimeout(() => advanceSpawn(id, 'shake-left'), 500 + 900);
    setTimeout(() => advanceSpawn(id, 'shake-right'), 500 + 900 + 350);
    setTimeout(() => advanceSpawn(id, 'working'), 500 + 900 + 350 + 350);
  };

  return (
    <div style={{ background: '#f5f3ee', minHeight: '100vh' }} className="px-6 py-10">
      <div className="max-w-[1280px] mx-auto">
        <header className="mb-10" />

        <div className="mb-8">
          <MacDesktop
            state={state}
            activeTaskId={activeTaskId}
            runningTaskIds={runningTaskIds}
            hovering={hovering}
            setHovering={setHovering}
            spawns={spawns}
            onRequestSpawn={handleSpawn}
            spawnInputOpen={spawnInputOpen}
            onCloseSpawnInput={() => setSpawnInputOpen(false)}
            desktopRef={desktopRef}
            desktopSize={desktopSize}
          />
          <div className="mt-3 flex items-center justify-center gap-3 text-xs text-gray-400">
            <button
              type="button"
              onClick={() => setSpawnInputOpen((v) => !v)}
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md border border-[#e5e3dc] bg-white hover:bg-gray-50 text-gray-700 transition"
            >
              <Plus size={12} />
              <span className="text-[11px] font-medium">New task</span>
              <span className="text-[9px] text-gray-400 font-mono ml-1">↵ to start</span>
            </button>
            {spawns.length > 0 && (
              <button
                type="button"
                onClick={() => setSpawns([])}
                className="text-[11px] text-gray-500 hover:text-gray-800 underline underline-offset-2"
              >
                clear {spawns.length} tasks
              </button>
            )}
            <span className="text-gray-400">·</span>
            <span>{hovering ? 'move away to collapse' : 'hover the notch to expand'}</span>
          </div>
        </div>

        <DemoControls
          state={state}
          setState={setState}
          activeTaskId={activeTaskId}
          setActiveTaskId={setActiveTaskId}
        />

        <div className="mt-10 pt-6 border-t border-gray-200 grid grid-cols-1 md:grid-cols-3 gap-6 text-[13px] text-gray-600">
          <div>
            <div className="font-medium text-gray-900 mb-1">Resting</div>
            <p className="leading-relaxed">Small pill, task color + live activity bars. Does not compete with your work.</p>
          </div>
          <div>
            <div className="font-medium text-gray-900 mb-1">Attention</div>
            <p className="leading-relaxed">Bulges with the task color. Check badge = done. Pulsing pink halo = needs you.</p>
          </div>
          <div>
            <div className="font-medium text-gray-900 mb-1">Expanded</div>
            <p className="leading-relaxed">Current work, statuses, and a task prompt. Background dims so focus stays on the task.</p>
          </div>
        </div>
      </div>
    </div>
  );
}

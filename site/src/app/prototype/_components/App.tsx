'use client';

import { type FormEvent, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

import { DemoControls } from '@/app/prototype/_components/DemoControls';
import { MacDesktop } from '@/app/prototype/_components/MacDesktop';
import {
  INITIAL_LIVE_TASKS,
  MAX_LIVE_TASKS,
  SAMPLE_SUBTEXTS,
  TASK_COLORS,
  TASK_DONE_AT_SECONDS,
  UPDATE_MESSAGES,
} from '@/app/prototype/_components/tasks';
import type { LiveTask, NotchState, NotchUpdate, NotchVariant, TaskId } from '@/app/prototype/_components/types';

const firstRunning = INITIAL_LIVE_TASKS.find((task) => task.status === 'running');
const INITIAL_UPDATE: NotchUpdate | null = firstRunning
  ? { color: firstRunning.color, message: firstRunning.detail }
  : null;

const COMPOSER_TEXT_MIN_HEIGHT = 19.2;
const COMPOSER_TEXT_MAX_HEIGHT = 134.4;

export default function App() {
  const [state, setState] = useState<NotchState>('running-single');
  const [notchVariant, setNotchVariant] = useState<NotchVariant>('real');
  // App-update notification is detected once on launch; the prototype seeds it on.
  const [updateAvailable, setUpdateAvailable] = useState(true);
  const [missingPermissions, setMissingPermissions] = useState(false);
  const [liveTasks, setLiveTasks] = useState<LiveTask[]>(INITIAL_LIVE_TASKS);
  // The update currently streaming into the collapsed notch chin (rotates across running tasks).
  const [chinUpdate, setChinUpdate] = useState<NotchUpdate | null>(INITIAL_UPDATE);
  // Completed tasks keep surfacing in the collapsed notch until the user expands; expanding marks
  // them acknowledged so they stop surfacing as floating pointers (they stay in the expanded list).
  const [acknowledgedDoneIds, setAcknowledgedDoneIds] = useState<Set<string>>(() => new Set());
  const acknowledgedDoneRef = useRef(acknowledgedDoneIds);
  const [activeTaskId, setActiveTaskId] = useState<TaskId>('compare');
  const [notchExpanded, setNotchExpanded] = useState(false);
  // Center composer is summoned with a double-tap of Cmd (like the app), hidden otherwise.
  const [composerVisible, setComposerVisible] = useState(false);
  const [promptText, setPromptText] = useState('');
  const [promptTextHeight, setPromptTextHeight] = useState(COMPOSER_TEXT_MIN_HEIGHT);
  const promptInputRef = useRef<HTMLTextAreaElement | null>(null);
  const liveTaskIdRef = useRef(0);
  const liveTasksRef = useRef(liveTasks);
  const updateCounterRef = useRef(0);

  useLayoutEffect(() => {
    const input = promptInputRef.current;
    if (!input) return;

    input.style.height = 'auto';
    const nextHeight = Math.min(
      Math.max(Math.ceil(input.scrollHeight), COMPOSER_TEXT_MIN_HEIGHT),
      COMPOSER_TEXT_MAX_HEIGHT,
    );
    input.style.height = `${nextHeight}px`;
    setPromptTextHeight(nextHeight);
  }, [promptText]);

  // Double-tap Cmd summons the composer; Escape dismisses it.
  useEffect(() => {
    let lastMetaAt = 0;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Meta') {
        const now = Date.now();
        if (now - lastMetaAt < 400) {
          lastMetaAt = 0;
          setComposerVisible(true);
        } else {
          lastMetaAt = now;
        }
      } else if (event.key === 'Escape') {
        setComposerVisible(false);
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  useEffect(() => {
    if (composerVisible) promptInputRef.current?.focus();
  }, [composerVisible]);

  // Any click outside the composer dismisses it.
  useEffect(() => {
    if (!composerVisible) return;

    const onPointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (target instanceof Element && target.closest('[aria-label="Donkey prompt"]')) return;
      setComposerVisible(false);
    };

    document.addEventListener('pointerdown', onPointerDown);
    return () => document.removeEventListener('pointerdown', onPointerDown);
  }, [composerVisible]);

  // Run the simulation: each running task's clock ticks up, finishing (→ done) at the cap.
  useEffect(() => {
    const interval = window.setInterval(() => {
      setLiveTasks((tasks) =>
        tasks.map((task) => {
          if (task.status !== 'running') return task;
          const seconds = task.seconds + 1;
          return seconds >= TASK_DONE_AT_SECONDS ? { ...task, seconds, status: 'done' } : { ...task, seconds };
        }),
      );
    }, 1000);

    return () => window.clearInterval(interval);
  }, []);

  // Keep a ref of the latest tasks so the rotation timer can read them without re-subscribing.
  useEffect(() => {
    liveTasksRef.current = liveTasks;
  }, [liveTasks]);

  // Keep a ref of the acknowledged set so the rotation timer can read it without re-subscribing.
  useEffect(() => {
    acknowledgedDoneRef.current = acknowledgedDoneIds;
  }, [acknowledgedDoneIds]);

  // Rotate the collapsed chin through running tasks' streaming updates, one at a time. When nothing
  // is running, keep surfacing the most recent completed task's result until the user dismisses it.
  useEffect(() => {
    const interval = window.setInterval(() => {
      const tasks = liveTasksRef.current;
      const running = tasks.filter((task) => task.status === 'running');
      if (running.length > 0) {
        updateCounterRef.current += 1;
        const task = running[updateCounterRef.current % running.length];
        const message = UPDATE_MESSAGES[updateCounterRef.current % UPDATE_MESSAGES.length];
        setChinUpdate({ color: task.color, message });
        return;
      }
      const done = tasks.find((task) => task.status === 'done' && !acknowledgedDoneRef.current.has(task.id));
      setChinUpdate(done ? { color: done.color, message: done.detail } : null);
    }, 2600);

    return () => window.clearInterval(interval);
  }, []);

  const addLiveTask = useCallback((title: string) => {
    liveTaskIdRef.current += 1;
    const color = TASK_COLORS[(INITIAL_LIVE_TASKS.length + liveTaskIdRef.current) % TASK_COLORS.length];
    const detail = SAMPLE_SUBTEXTS[liveTaskIdRef.current % SAMPLE_SUBTEXTS.length];
    const created: LiveTask = { id: `live-${liveTaskIdRef.current}`, title, detail, color, seconds: 0, status: 'running' };
    // New task goes to the front of the queue so the user sees it's processing right away.
    setLiveTasks((tasks) => (tasks.length >= MAX_LIVE_TASKS ? tasks : [created, ...tasks]));
    // Briefly surface the new task's own color + subtext before the rotation takes over.
    setChinUpdate({ color, message: detail });
  }, []);

  const stopLiveTask = useCallback((id: string) => {
    setLiveTasks((tasks) => tasks.map((task) => (task.id === id ? { ...task, status: 'stopped' } : task)));
  }, []);

  const resumeLiveTask = useCallback((id: string) => {
    setLiveTasks((tasks) => tasks.map((task) => (task.id === id ? { ...task, status: 'running' } : task)));
  }, []);

  const closeLiveTask = useCallback((id: string) => {
    setLiveTasks((tasks) => tasks.filter((task) => task.id !== id));
  }, []);

  const handleSubmit = useCallback((event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const taskText = promptText.trim();
    if (!taskText) return;

    // The composer adds a task to the notch list and runs it through the simulation.
    addLiveTask(taskText);
    setPromptText('');
    setComposerVisible(false);
  }, [addLiveTask, promptText]);

  const isNotchExpanded = notchExpanded || state === 'expanded-pinned';

  // Expanding the notch dismisses the surfaced completions: the running tasks keep streaming, but the
  // completed pointers that piled up in the collapsed notch are acknowledged and stop floating there.
  useEffect(() => {
    if (!isNotchExpanded) return;

    setAcknowledgedDoneIds((prev) => {
      let changed = false;
      const next = new Set(prev);
      for (const task of liveTasksRef.current) {
        if (task.status === 'done' && !next.has(task.id)) {
          next.add(task.id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [isNotchExpanded]);

  // The collapsed notch surfaces running tasks and completed-but-undismissed tasks as a pointer cluster.
  const surfacedTasks = liveTasks.filter(
    (task) => task.status === 'running' || (task.status === 'done' && !acknowledgedDoneIds.has(task.id)),
  );

  return (
    <div className="relative min-h-screen">
      <MacDesktop
        state={state}
        notchVariant={notchVariant}
        updateAvailable={updateAvailable}
        onRestart={() => setUpdateAvailable(false)}
        missingPermissions={missingPermissions}
        onReviewPermissions={() => setMissingPermissions(false)}
        notchExpanded={isNotchExpanded}
        setNotchExpanded={setNotchExpanded}
        composerVisible={composerVisible}
        promptText={promptText}
        setPromptText={setPromptText}
        promptInputRef={promptInputRef}
        promptTextHeight={promptTextHeight}
        onPromptSubmit={handleSubmit}
        liveTasks={liveTasks}
        surfacedTasks={surfacedTasks}
        chinUpdate={chinUpdate}
        onAddTask={addLiveTask}
        onStopTask={stopLiveTask}
        onResumeTask={resumeLiveTask}
        onCloseTask={closeLiveTask}
      />
      <DemoControls
        state={state}
        setState={setState}
        notchVariant={notchVariant}
        setNotchVariant={setNotchVariant}
        updateAvailable={updateAvailable}
        setUpdateAvailable={setUpdateAvailable}
        missingPermissions={missingPermissions}
        setMissingPermissions={setMissingPermissions}
        activeTaskId={activeTaskId}
        setActiveTaskId={setActiveTaskId}
      />
    </div>
  );
}

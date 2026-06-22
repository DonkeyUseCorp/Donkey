'use client';

import { type FormEvent, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

import { DemoControls } from '@/app/prototype/_components/DemoControls';
import { MacDesktop } from '@/app/prototype/_components/MacDesktop';
import {
  AUTH_ERROR_MESSAGE,
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
  // Out of credits gates the notch into a reload call-to-action; the prototype seeds it off.
  const [outOfCredits, setOutOfCredits] = useState(false);
  // Logged out gates the notch into a login call-to-action; the prototype seeds it off.
  const [loggedOut, setLoggedOut] = useState(false);
  const [liveTasks, setLiveTasks] = useState<LiveTask[]>(INITIAL_LIVE_TASKS);
  // The update currently streaming into the collapsed notch chin (rotates across running tasks).
  const [chinUpdate, setChinUpdate] = useState<NotchUpdate | null>(INITIAL_UPDATE);
  // Terminal tasks — completions and errors — keep surfacing in the collapsed notch until the user
  // expands; expanding marks them acknowledged so they stop surfacing as floating pointers / chin
  // messages (they stay in the expanded list).
  const [acknowledgedIds, setAcknowledgedIds] = useState<Set<string>>(() => new Set());
  const acknowledgedRef = useRef(acknowledgedIds);
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
    acknowledgedRef.current = acknowledgedIds;
  }, [acknowledgedIds]);

  // Rotate the collapsed chin through running tasks' streaming updates, one at a time. An
  // unacknowledged error outranks everything and holds the chin until the user expands; otherwise,
  // when nothing is running, the most recent completion keeps surfacing until it's acknowledged.
  useEffect(() => {
    const interval = window.setInterval(() => {
      const tasks = liveTasksRef.current;
      const errored = tasks.find((task) => task.status === 'error' && !acknowledgedRef.current.has(task.id));
      if (errored) {
        setChinUpdate({ color: errored.color, message: errored.detail, isError: true });
        return;
      }
      const running = tasks.filter((task) => task.status === 'running');
      if (running.length > 0) {
        updateCounterRef.current += 1;
        const task = running[updateCounterRef.current % running.length];
        const message = UPDATE_MESSAGES[updateCounterRef.current % UPDATE_MESSAGES.length];
        setChinUpdate({ color: task.color, message });
        return;
      }
      const done = tasks.find((task) => task.status === 'done' && !acknowledgedRef.current.has(task.id));
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

  // Simulate an auth error. It attaches to a real task (the most recent running one, else any live
  // task) so the error is tied to that task's own pointer — the chin holds its message with a red
  // warning glyph in the right rail until the user expands to acknowledge it. Only when there's no
  // task to attach to does it synthesize one, so the demo can still show the error chin.
  const triggerAuthError = useCallback(() => {
    const tasks = liveTasksRef.current;
    const target = tasks.find((task) => task.status === 'running') ?? tasks.find((task) => task.status !== 'error');
    if (target) {
      setLiveTasks((current) =>
        current.map((task) =>
          task.id === target.id ? { ...task, status: 'error', detail: AUTH_ERROR_MESSAGE } : task,
        ),
      );
      setChinUpdate({ color: target.color, message: AUTH_ERROR_MESSAGE, isError: true });
      return;
    }

    liveTaskIdRef.current += 1;
    const color = TASK_COLORS[(INITIAL_LIVE_TASKS.length + liveTaskIdRef.current) % TASK_COLORS.length];
    const created: LiveTask = {
      id: `live-${liveTaskIdRef.current}`,
      title: 'Authentication required',
      detail: AUTH_ERROR_MESSAGE,
      color,
      seconds: 0,
      status: 'error',
    };
    setLiveTasks((current) => (current.length >= MAX_LIVE_TASKS ? current : [created, ...current]));
    setChinUpdate({ color, message: AUTH_ERROR_MESSAGE, isError: true });
  }, []);

  const stopLiveTask = useCallback((id: string) => {
    setLiveTasks((tasks) => tasks.map((task) => (task.id === id ? { ...task, status: 'stopped' } : task)));
  }, []);

  const resumeLiveTask = useCallback((id: string) => {
    setLiveTasks((tasks) => tasks.map((task) => (task.id === id ? { ...task, status: 'running' } : task)));
  }, []);

  // Replying to a thread continues it with the user's message: the task goes back to running and its
  // line shows what the user just said, mirroring the app's "pin the next message to this task".
  const replyToLiveTask = useCallback((id: string, text: string) => {
    setLiveTasks((tasks) =>
      tasks.map((task) => (task.id === id ? { ...task, status: 'running', detail: text } : task)),
    );
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

  // Expanding the notch acknowledges the surfaced terminal tasks: the running tasks keep streaming,
  // but the completions and errors that piled up in the collapsed notch (pointers + the held error
  // chin) are acknowledged and stop surfacing there.
  useEffect(() => {
    if (!isNotchExpanded) return;

    setAcknowledgedIds((prev) => {
      let changed = false;
      const next = new Set(prev);
      for (const task of liveTasksRef.current) {
        if ((task.status === 'done' || task.status === 'error') && !next.has(task.id)) {
          next.add(task.id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [isNotchExpanded]);

  // The collapsed notch surfaces running tasks plus unacknowledged terminal tasks (completions and
  // errors) as a pointer cluster.
  const surfacedTasks = liveTasks.filter(
    (task) =>
      task.status === 'running' ||
      ((task.status === 'done' || task.status === 'error') && !acknowledgedIds.has(task.id)),
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
        outOfCredits={outOfCredits}
        onReloadCredits={() => setOutOfCredits(false)}
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
        onReplyToTask={replyToLiveTask}
        onCloseTask={closeLiveTask}
        loggedOut={loggedOut}
        onLogin={() => setLoggedOut(false)}
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
        outOfCredits={outOfCredits}
        setOutOfCredits={setOutOfCredits}
        loggedOut={loggedOut}
        setLoggedOut={setLoggedOut}
        activeTaskId={activeTaskId}
        setActiveTaskId={setActiveTaskId}
        onTriggerAuthError={triggerAuthError}
      />
    </div>
  );
}

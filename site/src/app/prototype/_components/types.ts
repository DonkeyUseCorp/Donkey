export type TaskId = 'compare' | 'research' | 'reply' | 'schedule' | 'update';

export type NotchState =
  | 'idle'
  | 'running-single'
  | 'running-multi'
  | 'complete'
  | 'needs-input'
  | 'expanded-pinned';

// 'real' targets devices with a hardware notch (content flanks the void, chin hangs below).
// 'simulated' targets devices without one (external displays); a free-floating pill.
export type NotchVariant = 'real' | 'simulated';

export type TaskSample = {
  id: TaskId;
  label: string;
  color: string;
  detail: string;
};

// 'running' ticks; 'stopped' is paused (resume or close); 'done' is finished (close only).
export type LiveTaskStatus = 'running' | 'stopped' | 'done';

// The streaming update currently surfaced in the collapsed notch chin (with its task's color).
export type NotchUpdate = {
  color: string;
  message: string;
};

// A task shown in the expanded notch list.
export type LiveTask = {
  id: string;
  title: string;
  detail: string;
  color: string;
  seconds: number;
  status: LiveTaskStatus;
};

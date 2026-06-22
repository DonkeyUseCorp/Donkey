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

// 'running' ticks; 'stopped' is paused (resume or close); 'done' is finished; 'waiting' means the
// agent is blocked on the user (a clarification or review — the only state with a Reply button, since
// only there is the agent asking); 'error' is a terminal failure (e.g. an auth error) that keeps
// surfacing until acknowledged. 'waiting', 'done', and 'error' threads are repliable: the user taps the
// row to pick them back up.
export type LiveTaskStatus = 'running' | 'stopped' | 'done' | 'waiting' | 'error';

// The streaming update currently surfaced in the collapsed notch chin (with its task's color).
// `isError` marks a failure so the chin renders the warning icon in error red.
export type NotchUpdate = {
  color: string;
  message: string;
  isError?: boolean;
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

import type { LiveTask, TaskId, TaskSample } from '@/app/prototype/_components/types';

export const TASKS: Record<TaskId, TaskSample> = {
  compare: { id: 'compare', label: 'Compare options', color: '#1D9E75', detail: 'Ranking the best choices' },
  research: { id: 'research', label: 'Gather research', color: '#EF9F27', detail: 'Reading sources' },
  reply: { id: 'reply', label: 'Draft a reply', color: '#D4537E', detail: 'Writing the message' },
  schedule: { id: 'schedule', label: 'Plan a time', color: '#378ADD', detail: 'Finding open slots' },
  update: { id: 'update', label: 'Update a file', color: '#7F77DD', detail: 'Making edits' },
};

export const ALL_TASK_IDS = ['compare', 'research', 'reply', 'schedule', 'update'] satisfies TaskId[];

export const TASK_COLORS = ['#1D9E75', '#EF9F27', '#D4537E', '#378ADD', '#7F77DD', '#E15A47', '#3DB0B5', '#A856C9'];

export const MAX_LIVE_TASKS = 8;

// Subtext shown under a task title (and shown briefly in the chin when a task is added). Round-robin.
export const SAMPLE_SUBTEXTS = [
  'Reading the linked sources',
  'Ranking the best options',
  'Drafting the message',
  'Finding open time slots',
  'Comparing prices across sites',
  'Summarizing the thread',
  'Checking the latest figures',
  'Pulling the relevant files together',
];

// Streaming updates a running task emits; the collapsed chin rotates through these.
export const UPDATE_MESSAGES = [
  'Searching for the most relevant results…',
  'Comparing the top options side by side…',
  'Found a strong match — verifying it…',
  'Reading through the linked document…',
  'Summarizing what I found so far…',
  'Cross-referencing the latest figures…',
  'Drafting a response for you to review…',
  'Tidying up the details…',
  'Almost done — finalizing the results…',
];

// A running task finishes (→ done) once it reaches this elapsed time.
export const TASK_DONE_AT_SECONDS = 180;

export const INITIAL_LIVE_TASKS: LiveTask[] = [
  {
    id: 'seed-long',
    title: 'Summarize the research thread',
    detail:
      'Reading through the full discussion, pulling out every decision and open question, cross-referencing the linked documents, and drafting a structured summary that captures the key trade-offs, who raised them, and what still needs a follow-up before this can ship.',
    color: TASKS.update.color,
    seconds: 64,
    status: 'running',
  },
  { id: 'seed-1', title: TASKS.compare.label, detail: TASKS.compare.detail, color: TASKS.compare.color, seconds: 95, status: 'running' },
  { id: 'seed-2', title: TASKS.research.label, detail: TASKS.research.detail, color: TASKS.research.color, seconds: 527, status: 'stopped' },
  { id: 'seed-3', title: TASKS.reply.label, detail: TASKS.reply.detail, color: TASKS.reply.color, seconds: 180, status: 'done' },
  { id: 'seed-4', title: TASKS.schedule.label, detail: TASKS.schedule.detail, color: TASKS.schedule.color, seconds: 40, status: 'running' },
];

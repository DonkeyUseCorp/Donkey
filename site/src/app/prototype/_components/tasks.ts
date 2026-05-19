import type { TaskId, TaskSample } from '@/app/prototype/_components/types';

export const TASKS: Record<TaskId, TaskSample> = {
  compare: { id: 'compare', label: 'Compare options', color: '#1D9E75', detail: 'Ranking the best choices' },
  research: { id: 'research', label: 'Gather research', color: '#EF9F27', detail: 'Reading sources' },
  reply: { id: 'reply', label: 'Draft a reply', color: '#D4537E', detail: 'Writing the message' },
  schedule: { id: 'schedule', label: 'Plan a time', color: '#378ADD', detail: 'Finding open slots' },
  update: { id: 'update', label: 'Update a file', color: '#7F77DD', detail: 'Making edits' },
};

export const ALL_TASK_IDS = ['compare', 'research', 'reply', 'schedule', 'update'] satisfies TaskId[];

export const TASK_COLORS = ['#1D9E75', '#EF9F27', '#D4537E', '#378ADD', '#7F77DD', '#E15A47', '#3DB0B5', '#A856C9'];

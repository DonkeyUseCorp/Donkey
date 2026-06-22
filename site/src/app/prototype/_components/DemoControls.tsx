import { Check, ChevronDown } from 'lucide-react';
import { useState } from 'react';

import { DonkeyCursor } from '@/app/prototype/_components/DonkeyCursor';
import { ALL_TASK_IDS, TASKS } from '@/app/prototype/_components/tasks';
import type { NotchState, NotchVariant, TaskId } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  setState: (state: NotchState) => void;
  notchVariant: NotchVariant;
  setNotchVariant: (variant: NotchVariant) => void;
  updateAvailable: boolean;
  setUpdateAvailable: (available: boolean) => void;
  missingPermissions: boolean;
  setMissingPermissions: (missing: boolean) => void;
  outOfCredits: boolean;
  setOutOfCredits: (out: boolean) => void;
  activeTaskId: TaskId;
  setActiveTaskId: (id: TaskId) => void;
  onTriggerAuthError: () => void;
  loggedOut: boolean;
  setLoggedOut: (loggedOut: boolean) => void;
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

const VARIANT_OPTIONS: { id: NotchVariant; label: string }[] = [
  { id: 'real', label: 'Real' },
  { id: 'simulated', label: 'Sim' },
];

export function DemoControls({
  state,
  setState,
  notchVariant,
  setNotchVariant,
  updateAvailable,
  setUpdateAvailable,
  missingPermissions,
  setMissingPermissions,
  outOfCredits,
  setOutOfCredits,
  activeTaskId,
  setActiveTaskId,
  onTriggerAuthError,
  loggedOut,
  setLoggedOut,
}: Props) {
  const [notificationsOpen, setNotificationsOpen] = useState(false);

  const notifications = [
    { label: 'Out of Credits', on: outOfCredits, toggle: () => setOutOfCredits(!outOfCredits) },
    { label: 'Update Available', on: updateAvailable, toggle: () => setUpdateAvailable(!updateAvailable) },
    { label: 'Missing Permissions', on: missingPermissions, toggle: () => setMissingPermissions(!missingPermissions) },
  ];
  const activeNotifications = notifications.filter((notification) => notification.on).length;

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
        {VARIANT_OPTIONS.map((option) => {
          const active = notchVariant === option.id;

          return (
            <button
              key={option.id}
              type="button"
              onClick={() => setNotchVariant(option.id)}
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

      <button
        type="button"
        onClick={onTriggerAuthError}
        className="h-8 rounded-lg px-2.5 text-[11px] font-medium transition"
        style={{ background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.72)' }}
      >
        Auth error
      </button>

      <button
        type="button"
        onClick={() => setLoggedOut(!loggedOut)}
        className="h-8 rounded-lg px-2.5 text-[11px] font-medium transition"
        style={{
          background: loggedOut ? 'rgba(255,255,255,0.92)' : 'rgba(255,255,255,0.08)',
          color: loggedOut ? 'rgba(0,0,0,0.82)' : 'rgba(255,255,255,0.72)',
        }}
      >
        Logged out
      </button>

      <div className="h-7 w-px bg-white/10" />

      <div className="relative flex items-center gap-1.5">
        <button
          type="button"
          onClick={() => setNotificationsOpen((open) => !open)}
          className="flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-[11px] font-medium transition"
          style={{
            background: activeNotifications > 0 ? 'rgba(255,255,255,0.92)' : 'rgba(255,255,255,0.08)',
            color: activeNotifications > 0 ? 'rgba(0,0,0,0.82)' : 'rgba(255,255,255,0.72)',
          }}
        >
          Notifications{activeNotifications > 0 ? ` · ${activeNotifications}` : ''}
          <ChevronDown size={12} />
        </button>
        {notificationsOpen && (
          <>
            <button
              type="button"
              aria-label="Close notifications menu"
              className="fixed inset-0 z-40 cursor-default"
              onClick={() => setNotificationsOpen(false)}
            />
            <div className="absolute bottom-full right-0 z-50 mb-2 w-52 rounded-lg border border-white/10 bg-[#1b1c20] p-1 shadow-2xl">
              {notifications.map((notification) => (
                <button
                  key={notification.label}
                  type="button"
                  onClick={notification.toggle}
                  className="flex w-full items-center justify-between gap-3 rounded-md px-2.5 py-2 text-left text-[12px] text-white/[0.82] transition hover:bg-white/[0.08]"
                >
                  {notification.label}
                  {notification.on && <Check size={14} className="text-white" />}
                </button>
              ))}
            </div>
          </>
        )}
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
    </aside>
  );
}

import { ArrowUp, Mic } from 'lucide-react';
import type { FormEvent, RefObject } from 'react';

import { Notch } from '@/app/prototype/_components/Notch';
import type { LiveTask, NotchState, NotchUpdate, NotchVariant } from '@/app/prototype/_components/types';

type Props = {
  state: NotchState;
  notchVariant: NotchVariant;
  updateAvailable: boolean;
  onRestart: () => void;
  missingPermissions: boolean;
  onReviewPermissions: () => void;
  notchExpanded: boolean;
  setNotchExpanded: (expanded: boolean) => void;
  composerVisible: boolean;
  promptText: string;
  setPromptText: (text: string) => void;
  promptInputRef: RefObject<HTMLTextAreaElement | null>;
  promptTextHeight: number;
  onPromptSubmit: (event: FormEvent<HTMLFormElement>) => void;
  liveTasks: LiveTask[];
  surfacedTasks: LiveTask[];
  chinUpdate: NotchUpdate | null;
  onAddTask: (title: string) => void;
  onStopTask: (id: string) => void;
  onResumeTask: (id: string) => void;
  onCloseTask: (id: string) => void;
};

const LAYOUT = {
  contentWidth: 592,
  stageHorizontalPadding: 8,
  stageVerticalPadding: 10,
  composerWidth: 576,
  // Single growing layout: one line by default, grows with content; controls pinned bottom-right.
  composerMinHeight: 56,
  composerCornerRadius: 28,
  composerTextMaxHeight: 134.4,
  composerMicrophoneSize: 28,
  composerSendButtonSize: 36.8,
} as const;

export function MacDesktop({
  state,
  notchVariant,
  updateAvailable,
  onRestart,
  missingPermissions,
  onReviewPermissions,
  notchExpanded,
  setNotchExpanded,
  composerVisible,
  promptText,
  setPromptText,
  promptInputRef,
  promptTextHeight,
  onPromptSubmit,
  liveTasks,
  surfacedTasks,
  chinUpdate,
  onAddTask,
  onStopTask,
  onResumeTask,
  onCloseTask,
}: Props) {
  const hasPromptText = promptText.trim().length > 0;

  return (
    <main
      className="relative min-h-screen overflow-hidden bg-[#121419] text-white"
      style={{ fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif' }}
    >
      <div
        className="absolute inset-0"
        style={{
          background:
            'linear-gradient(145deg, rgba(44,66,78,0.82) 0%, rgba(20,21,26,0.96) 45%, rgba(33,36,51,0.92) 100%)',
        }}
      />
      <div
        className="absolute inset-0"
        style={{
          background:
            'linear-gradient(180deg, rgba(0,0,0,0.18) 0%, rgba(0,0,0,0) 26%, rgba(0,0,0,0.32) 100%)',
        }}
      />

      <div
        className="absolute left-0 right-0 top-0 z-10 flex h-8 items-center gap-4 px-4 text-[13px] text-white/[0.72]"
        style={{
          background: 'rgba(11,12,15,0.55)',
          backdropFilter: 'blur(14px)',
        }}
      >
        <span className="font-medium text-white/[0.88]">Donkey</span>
        <span>File</span>
        <span>Edit</span>
        <span>View</span>
        <span>Go</span>
        <span>Window</span>
        <span>Help</span>
      </div>

      <Notch
        state={state}
        variant={notchVariant}
        updateAvailable={updateAvailable}
        onRestart={onRestart}
        missingPermissions={missingPermissions}
        onReviewPermissions={onReviewPermissions}
        expanded={notchExpanded}
        setExpanded={setNotchExpanded}
        liveTasks={liveTasks}
        surfacedTasks={surfacedTasks}
        chinUpdate={chinUpdate}
        onAddTask={onAddTask}
        onStopTask={onStopTask}
        onResumeTask={onResumeTask}
        onCloseTask={onCloseTask}
      />

      <section
        aria-label="Donkey prompt"
        className="absolute left-1/2 top-1/2 z-20"
        style={{
          width: LAYOUT.contentWidth,
          padding: `${LAYOUT.stageVerticalPadding}px ${LAYOUT.stageHorizontalPadding}px`,
          transform: `translate(-50%, -50%) scale(${composerVisible ? 1 : 0.98})`,
          opacity: composerVisible ? 1 : 0,
          pointerEvents: composerVisible ? 'auto' : 'none',
          transition: 'opacity 160ms ease-out, transform 160ms ease-out',
        }}
      >
        {/* Single layout: one line that grows with its text; controls pinned bottom-right. */}
        <form
          onSubmit={onPromptSubmit}
          className="relative flex items-center bg-black"
          style={{
            width: LAYOUT.composerWidth,
            minHeight: LAYOUT.composerMinHeight,
            borderRadius: LAYOUT.composerCornerRadius,
            padding: '10px 20px',
            boxShadow: '0 5px 12px rgba(0,0,0,0.2), inset 0 0 0 1px rgba(255,255,255,0.34)',
          }}
        >
          <label className="sr-only" htmlFor="donkey-prompt-input">
            Prompt
          </label>
          <textarea
            id="donkey-prompt-input"
            ref={promptInputRef}
            rows={1}
            value={promptText}
            onChange={(event) => setPromptText(event.target.value)}
            placeholder="What can donkey do for you?"
            className="flex-1 resize-none border-0 bg-transparent p-0 pr-[84px] text-[16px] font-light leading-[19.2px] text-white outline-none placeholder:text-white/[0.58]"
            style={{
              height: promptTextHeight,
              maxHeight: LAYOUT.composerTextMaxHeight,
              overflowY: 'auto',
              caretColor: 'white',
              fontVariantLigatures: 'none',
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                event.currentTarget.form?.requestSubmit();
              }
            }}
          />
          <div className="absolute bottom-2.5 right-3.5 flex items-center gap-2">
            <button
              type="button"
              className="grid place-items-center rounded-full transition"
              style={{
                width: LAYOUT.composerMicrophoneSize,
                height: LAYOUT.composerMicrophoneSize,
                color: hasPromptText ? 'rgba(255,255,255,0.42)' : 'rgba(255,255,255,0.78)',
              }}
              aria-label="Voice input"
            >
              <Mic size={24} strokeWidth={1.15} />
            </button>
            <button
              type="submit"
              className="grid place-items-center rounded-full transition disabled:cursor-default"
              style={{
                width: LAYOUT.composerSendButtonSize,
                height: LAYOUT.composerSendButtonSize,
                background: hasPromptText ? 'rgba(255,255,255,0.94)' : 'rgba(255,255,255,0.68)',
                color: hasPromptText ? 'rgba(0,0,0,0.78)' : 'rgba(0,0,0,0.42)',
              }}
              disabled={!hasPromptText}
              aria-label="Send"
            >
              <ArrowUp size={18} strokeWidth={2.25} />
            </button>
          </div>
        </form>
      </section>
    </main>
  );
}

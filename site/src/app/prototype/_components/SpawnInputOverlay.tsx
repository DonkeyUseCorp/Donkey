import { useCallback, useEffect, useRef, useState } from 'react';
import { Sparkles } from 'lucide-react';
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';

type Props = {
  onSubmit: (taskText: string) => void;
  onClose: () => void;
};

export function SpawnInputOverlay({ onSubmit, onClose }: Props) {
  const [text, setText] = useState('');
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    setTimeout(() => inputRef.current?.focus(), 50);
  }, []);

  useEffect(() => {
    const handleWindowKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;

      onClose();
    };

    window.addEventListener('keydown', handleWindowKey);
    return () => window.removeEventListener('keydown', handleWindowKey);
  }, [onClose]);

  const handleKey = useCallback((e: ReactKeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && text.trim()) {
      onSubmit(text.trim());
      setText('');
    } else if (e.key === 'Escape') {
      onClose();
    }
  }, [onClose, onSubmit, text]);

  return (
    <div
      className="absolute left-1/2 -translate-x-1/2 z-30"
      style={{ top: 56, animation: 'fadein-input 0.25s cubic-bezier(0.32, 0.72, 0, 1) both' }}
    >
      <style>{`
        @keyframes fadein-input {
          from { opacity: 0; transform: translate(-50%, -8px); }
          to { opacity: 1; transform: translate(-50%, 0); }
        }
      `}</style>
      <div className="bg-black/90 backdrop-blur rounded-xl px-3 py-2.5 flex items-center gap-2 shadow-xl border border-white/10" style={{ width: 360 }}>
        <Sparkles size={13} color="rgba(255,255,255,0.6)" />
        <input
          ref={inputRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={handleKey}
          placeholder="Ask Donkey to…"
          className="bg-transparent border-0 outline-none flex-1 text-[12px] text-white placeholder-white/40"
        />
        <button
          type="button"
          onClick={() => text.trim() && (onSubmit(text.trim()), setText(''))}
          disabled={!text.trim()}
          className="text-[9px] text-white/70 px-1.5 py-px border border-white/15 rounded font-mono disabled:opacity-30"
        >
          ↵
        </button>
      </div>
    </div>
  );
}

import { useState, useEffect, useRef, useLayoutEffect } from 'react';
import { Code, Globe, Search, Mail, Calendar, Smile, Moon, Plus, Sparkles, Check, Play, Apple, Wifi, BatteryFull } from 'lucide-react';

const AGENTS = {
  coder:      { id: 'coder',      name: 'Coder',      color: '#1D9E75', Icon: Code,     subtitle: 'Ranking models on SWE-bench' },
  browser:    { id: 'browser',    name: 'Browser',    color: '#EF9F27', Icon: Globe,    subtitle: 'Pulling pricing from 3 sites' },
  researcher: { id: 'researcher', name: 'Researcher', color: '#D4537E', Icon: Search,   subtitle: 'Reading 12 ArXiv papers' },
  inbox:      { id: 'inbox',      name: 'Inbox',      color: '#378ADD', Icon: Mail,     subtitle: 'Drafting reply to recruiter' },
  scheduler:  { id: 'scheduler',  name: 'Scheduler',  color: '#7F77DD', Icon: Calendar, subtitle: 'Finding slots across KST/PT' },
};
const ALL_AGENT_IDS = ['coder', 'browser', 'researcher', 'inbox', 'scheduler'];

function ActivityBars({ color = '#fff' }) {
  return (
    <>
      <style>{`
        @keyframes ab1 { 0%,100%{height:7px;opacity:1} 50%{height:3px;opacity:0.5} }
        @keyframes ab2 { 0%,100%{height:4px;opacity:0.6} 50%{height:9px;opacity:1} }
        @keyframes ab3 { 0%,100%{height:9px;opacity:1} 50%{height:5px;opacity:0.7} }
        .ab1 { animation: ab1 1.1s ease-in-out infinite; }
        .ab2 { animation: ab2 1.1s ease-in-out infinite; }
        .ab3 { animation: ab3 1.1s ease-in-out infinite; }
      `}</style>
      <div className="flex gap-[2px] items-center flex-shrink-0">
        <div className="w-[2px] rounded-sm ab1" style={{ background: color }} />
        <div className="w-[2px] rounded-sm ab2" style={{ background: color }} />
        <div className="w-[2px] rounded-sm ab3" style={{ background: color }} />
      </div>
    </>
  );
}

function Notch({ state, activeAgentId, hovering, setHovering, runningIds }) {
  const activeAgent = AGENTS[activeAgentId] || AGENTS.coder;
  const isExpanded = hovering || state === 'expanded-pinned';

  const isComplete = state === 'complete';
  const isAttention = state === 'needs-input';
  const isMulti = state === 'running-multi';
  const isHero = isComplete || isAttention;

  // Width strategy:
  // - Expanded / hero / multi states use fixed widths (they have predictable content layouts)
  // - Resting "running-single" sizes to content with a min/max so long agent subtitles don't get clipped
  let widthStyle;
  if (isExpanded) widthStyle = { width: '440px' };
  else if (isHero) widthStyle = { width: '360px' };
  else if (isMulti) widthStyle = { width: '220px' };
  else if (state === 'running-single') widthStyle = { width: 'fit-content', minWidth: '200px', maxWidth: '460px' };
  else widthStyle = { width: '200px' }; // idle

  const ringColor = isComplete
    ? 'rgba(29,158,117,0.55)'
    : isAttention
    ? 'rgba(212,83,126,0.65)'
    : 'transparent';

  const ActiveIcon = activeAgent.Icon;

  return (
    <div
      className="absolute top-0 left-1/2 -translate-x-1/2 z-20"
      style={{
        ...widthStyle,
        transition: 'width 0.4s cubic-bezier(0.32, 0.72, 0, 1), min-width 0.4s cubic-bezier(0.32, 0.72, 0, 1), max-width 0.4s cubic-bezier(0.32, 0.72, 0, 1)',
      }}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
    >
      <style>{`
        @keyframes pulseRing {
          0%,100% { box-shadow: 0 0 0 1.5px var(--ring), 0 0 0 0 rgba(212,83,126,0); }
          50% { box-shadow: 0 0 0 1.5px var(--ring), 0 0 0 6px rgba(212,83,126,0.15); }
        }
        @keyframes fadeinUp {
          from { opacity: 0; transform: translateY(-4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .pulse-attention { animation: pulseRing 1.6s ease-in-out infinite; }
        .fadein-up { animation: fadeinUp 0.3s cubic-bezier(0.32, 0.72, 0, 1) both; }
      `}</style>
      <div
        className={`bg-black mx-auto text-white overflow-hidden ${isAttention && !isExpanded ? 'pulse-attention' : ''}`}
        style={{
          width: '100%',
          borderRadius: isExpanded ? '0 0 22px 22px' : isHero ? '0 0 22px 22px' : '0 0 14px 14px',
          boxShadow: !isExpanded && ringColor !== 'transparent' ? `0 0 0 1.5px ${ringColor}` : 'none',
          transition: 'border-radius 0.4s cubic-bezier(0.32, 0.72, 0, 1), box-shadow 0.3s ease',
          '--ring': ringColor,
        }}
      >
        {!isExpanded && (state === 'idle' || state === 'running-single') && (
          <div className="flex items-center justify-center gap-2 pl-3.5 pr-4 py-1.5">
            <div
              className="w-3.5 h-3.5 rounded-full flex items-center justify-center flex-shrink-0"
              style={{ background: state === 'idle' ? '#444' : activeAgent.color }}
            >
              {state === 'idle' ? <Moon size={8} color="#fff" /> : <ActiveIcon size={8} color="#fff" />}
            </div>
            <span className="text-[10px] font-medium tracking-tight whitespace-nowrap text-white/95">
              {state === 'idle'
                ? 'Donkey · resting'
                : `${activeAgent.name} · ${activeAgent.subtitle.toLowerCase()}`}
            </span>
            {state === 'running-single' && <ActivityBars color={activeAgent.color} />}
          </div>
        )}

        {!isExpanded && isMulti && (
          <div className="flex items-center justify-center gap-2 px-3 py-1.5">
            <div className="flex items-center">
              {runningIds.slice(0, 4).map((id, i) => (
                <div
                  key={id}
                  className="w-3 h-3 rounded-full"
                  style={{
                    background: AGENTS[id].color,
                    border: '1.5px solid #000',
                    marginLeft: i === 0 ? 0 : '-4px',
                    zIndex: 10 - i,
                  }}
                />
              ))}
            </div>
            <span className="text-[10px] font-medium text-white/95 whitespace-nowrap">
              {runningIds.length} agents working
            </span>
            <ActivityBars color="rgba(255,255,255,0.85)" />
          </div>
        )}

        {!isExpanded && isComplete && (
          <div className="flex items-center gap-2.5 px-4 pt-1.5 pb-2.5 fadein-up">
            <div className="relative flex-shrink-0">
              <div className="w-7 h-7 rounded-md flex items-center justify-center" style={{ background: activeAgent.color }}>
                <ActiveIcon size={14} color="#fff" />
              </div>
              <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-white flex items-center justify-center">
                <Check size={8} color={activeAgent.color} strokeWidth={3} />
              </div>
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-1.5">
                <span className="text-[11px] font-medium">{activeAgent.name} finished</span>
                <span className="text-[9px] text-white/50">· 1m 42s</span>
              </div>
              <div className="text-[10px] text-white/65 truncate">{activeAgent.subtitle}</div>
            </div>
            <button
              className="text-[10px] font-medium px-2 py-1 rounded"
              style={{ background: `${activeAgent.color}66`, color: '#fff' }}
            >
              View
            </button>
          </div>
        )}

        {!isExpanded && isAttention && (
          <div className="flex items-center gap-2.5 px-4 pt-1.5 pb-2.5 fadein-up">
            <div className="relative flex-shrink-0">
              <div className="w-7 h-7 rounded-md flex items-center justify-center" style={{ background: activeAgent.color }}>
                <ActiveIcon size={14} color="#fff" />
              </div>
              <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-white flex items-center justify-center">
                <span style={{ fontSize: '9px', color: activeAgent.color, fontWeight: 700, lineHeight: 1 }}>!</span>
              </div>
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-1.5">
                <span className="text-[11px] font-medium">{activeAgent.name} needs you</span>
                <span className="text-[9px] text-white/50">· paused</span>
              </div>
              <div className="text-[10px] text-white/65 truncate">Pick a source for the search</div>
            </div>
            <button
              className="text-[10px] font-medium px-2 py-1 rounded"
              style={{ background: `${activeAgent.color}80`, color: '#fff' }}
            >
              Answer
            </button>
          </div>
        )}

        {isExpanded && (
          <div className="fadein-up">
            <div className="px-3.5 pt-2 pb-2 flex items-center gap-2 border-b border-white/10">
              <div className="w-3.5 h-3.5 rounded-full flex items-center justify-center" style={{ background: '#1D9E75' }}>
                <Smile size={8} color="#fff" />
              </div>
              <span className="text-[11px] font-medium">Donkey</span>
              <span className="text-[10px] text-white/45 ml-1">{runningIds.length} of 5 running</span>
              <div className="ml-auto flex items-center gap-1 text-[10px] text-white/45 hover:text-white/80 cursor-pointer">
                <Plus size={11} />
                <span>new task</span>
              </div>
            </div>

            <div className="p-2 flex flex-col gap-1">
              {ALL_AGENT_IDS.map((id) => {
                const a = AGENTS[id];
                const IconC = a.Icon;
                const isRunning = runningIds.includes(id);
                const isActiveStateAgent = activeAgentId === id && (state === 'complete' || state === 'needs-input');
                let statusLabel = isRunning ? 'running' : 'idle';
                let statusColor = isRunning ? a.color : 'rgba(255,255,255,0.4)';
                if (isActiveStateAgent && state === 'complete') statusLabel = 'done';
                if (isActiveStateAgent && state === 'needs-input') {
                  statusLabel = 'needs you';
                  statusColor = a.color;
                }

                return (
                  <div
                    key={id}
                    className="flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-white/5 cursor-pointer"
                    style={isRunning ? { background: `${a.color}1A`, borderLeft: `2px solid ${a.color}` } : {}}
                  >
                    <div className="w-5 h-5 rounded flex items-center justify-center flex-shrink-0" style={{ background: a.color }}>
                      <IconC size={11} color="#fff" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-1.5">
                        <span className="text-[10px] font-medium">{a.name}</span>
                        <span
                          className="text-[9px] px-1 py-px rounded"
                          style={{
                            background: `${statusColor}30`,
                            color: statusColor === 'rgba(255,255,255,0.4)' ? 'rgba(255,255,255,0.5)' : statusColor,
                          }}
                        >
                          {statusLabel}
                        </span>
                      </div>
                      <div className="text-[9px] text-white/50 truncate">{isRunning ? a.subtitle : 'No active task'}</div>
                    </div>
                    {isRunning ? (
                      <ActivityBars color={a.color} />
                    ) : (
                      <Play size={11} color="rgba(255,255,255,0.4)" fill="rgba(255,255,255,0.4)" />
                    )}
                  </div>
                );
              })}
            </div>

            <div className="mx-2 mb-2 px-2.5 py-2 bg-white/[0.06] rounded-md flex items-center gap-2">
              <Sparkles size={11} color="rgba(255,255,255,0.5)" />
              <span className="text-[10px] text-white/40 flex-1">Tell donkey what to do…</span>
              <span className="text-[9px] text-white/30 px-1.5 py-px border border-white/15 rounded font-mono">⌘ K</span>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function DonkeyCursor({ color, size = 28 }) {
  // The SVG's natural tip is at (~83, 5) in its 100x100 viewBox space (upper-right).
  // We position the SVG so that tip lands at the container's (0,0). That way, when
  // this element is placed on an offset-path or rotated, the TIP is the anchor.
  const tipX = 83 * (size / 100);
  const tipY = 5 * (size / 100);

  return (
    <div className="relative" style={{ width: 0, height: 0 }}>
      <svg
        viewBox="-5 -10 110 135"
        width={size}
        height={size}
        style={{
          position: 'absolute',
          left: -tipX,
          top: -tipY,
          filter: 'drop-shadow(0 2px 4px rgba(0,0,0,0.4))',
          overflow: 'visible',
        }}
      >
        <path
          d="m83.086 5.6406-72.633 29.043c-7.6016 3.0391-7.1445 13.949 0.67969 16.344l24.562 7.5195c2.7539 0.84375 4.9102 3 5.7539 5.7539l7.5195 24.562c2.3984 7.8281 13.305 8.2812 16.344 0.67969l29.043-72.633c2.832-7.0781-4.1953-14.102-11.273-11.273z"
          fill={color}
          stroke="white"
          strokeWidth="6"
          strokeLinejoin="round"
        />
      </svg>
    </div>
  );
}

function SpawnedCursor({ spawn, notchAnchor }) {
  // Each spawn carries its own CSS path. We use CSS offset-path to follow a Bézier curve.
  const { id, color, label, target, phase } = spawn;

  // Build a curved path from notchAnchor to target with a midpoint perpendicular offset
  const sx = notchAnchor.x, sy = notchAnchor.y;
  const tx = target.x, ty = target.y;
  const mx = (sx + tx) / 2;
  const my = (sy + ty) / 2;
  const dx = tx - sx, dy = ty - sy;
  const len = Math.hypot(dx, dy) || 1;
  const px = -dy / len, py = dx / len;
  const curveAmount = Math.min(80, len * 0.35) * (spawn.curveSide || 1);
  const cx = mx + px * curveAmount;
  const cy = my + py * curveAmount;
  const pathD = `M ${sx},${sy} Q ${cx},${cy} ${tx},${ty}`;

  // Final approach angle, used to keep the cursor pointing the right direction after travel ends.
  // The tangent at t=1 of a quadratic Bézier is (P2 - P1), i.e. (tx-cx, ty-cy).
  const endAngleDeg = (Math.atan2(ty - cy, tx - cx) * 180) / Math.PI;

  const isEmerge = phase === 'emerge';
  const isTravel = phase === 'travel';
  const isShakeL = phase === 'shake-left';
  const isShakeR = phase === 'shake-right';
  const isWorking = phase === 'working';

  // Use offset-path for emerge + travel. After that, the cursor is "parked" at target.
  const useOffsetPath = isEmerge || isTravel;

  // The cursor SVG's natural tip-to-tail axis points up-and-right at ~-50° in screen space.
  // For `offset-rotate: auto` (which rotates so element's +X aligns with path tangent) to
  // make the tip lead, we pre-rotate the artwork by +50° so its tip points right at rest.
  const CURSOR_BASE_ROTATION = 50;

  return (
    <>
      <style>{`
        @keyframes emerge-${id} {
          0%   { offset-distance: 0%; opacity: 0; }
          40%  { opacity: 1; }
          100% { offset-distance: 0%; opacity: 1; }
        }
        @keyframes emergeScale-${id} {
          0%   { transform: rotate(${CURSOR_BASE_ROTATION}deg) scale(0.2); }
          50%  { transform: rotate(${CURSOR_BASE_ROTATION}deg) scale(1.2); }
          100% { transform: rotate(${CURSOR_BASE_ROTATION}deg) scale(1); }
        }
        @keyframes travel-${id} {
          0%   { offset-distance: 0%; }
          100% { offset-distance: 100%; }
        }
        @keyframes shakeL-${id} {
          0%, 100% { transform: rotate(0deg); }
          25%      { transform: rotate(-14deg); }
          75%      { transform: rotate(-7deg); }
        }
        @keyframes shakeR-${id} {
          0%, 100% { transform: rotate(0deg); }
          25%      { transform: rotate(14deg); }
          75%      { transform: rotate(7deg); }
        }
        @keyframes working-${id} {
          0%, 100% { transform: scale(1); }
          50%      { transform: scale(1.08); }
        }
        @keyframes haloPulse-${id} {
          0%, 100% { transform: scale(1); opacity: 0.6; }
          50%      { transform: scale(1.15); opacity: 0.2; }
        }
      `}</style>

      {/* Working halo (appears when settled) */}
      {isWorking && (
        <div
          className="absolute pointer-events-none"
          style={{
            left: target.x - 18,
            top: target.y - 18,
            width: 36,
            height: 36,
            borderRadius: '50%',
            border: `1.5px solid ${color}`,
            animation: `haloPulse-${id} 1.6s ease-in-out infinite`,
            zIndex: 29,
          }}
        />
      )}

      {/* OUTER positioner: handles offset-path travel OR fixed position at target */}
      <div
        className="absolute pointer-events-none"
        style={{
          left: useOffsetPath ? 0 : target.x,
          top: useOffsetPath ? 0 : target.y,
          ...(useOffsetPath && {
            offsetPath: `path("${pathD}")`,
            WebkitOffsetPath: `path("${pathD}")`,
            // 'auto' rotates along the tangent of the path. The extra angle is the
            // base rotation needed because the cursor artwork doesn't natively point right.
            offsetRotate: `auto ${CURSOR_BASE_ROTATION}deg`,
            WebkitOffsetRotate: `auto ${CURSOR_BASE_ROTATION}deg`,
            animation: isEmerge
              ? `emerge-${id} 0.5s cubic-bezier(0.32, 1.4, 0.5, 1) forwards`
              : `travel-${id} 0.9s cubic-bezier(0.45, 0.05, 0.3, 1) forwards`,
          }),
          zIndex: 30,
        }}
      >
        {/* MIDDLE rotator: holds the post-travel base orientation, plus shake/wiggle */}
        <div
          style={{
            transform: useOffsetPath ? 'none' : `rotate(${endAngleDeg + CURSOR_BASE_ROTATION}deg)`,
            transformOrigin: '0 0', // pivot at the cursor tip
          }}
        >
          {/* INNER animator: shake/working scale animations */}
          <div
            style={{
              transformOrigin: '0 0',
              animation: isEmerge
                ? `emergeScale-${id} 0.5s cubic-bezier(0.32, 1.4, 0.5, 1) forwards`
                : isShakeL
                ? `shakeL-${id} 0.35s ease-in-out`
                : isShakeR
                ? `shakeR-${id} 0.35s ease-in-out`
                : isWorking
                ? `working-${id} 1.4s ease-in-out infinite`
                : 'none',
            }}
          >
            <DonkeyCursor color={color} />
          </div>
        </div>
      </div>

      {/* Upright label — positioned in screen space, offset behind the cursor's tail
          (opposite the direction the tip points). Anchored by the edge facing the
          cursor, so longer labels don't creep closer. */}
      {(isShakeL || isShakeR || isWorking) && label && (
        (() => {
          // Unit vector pointing in the direction the cursor's tip points
          const rad = (endAngleDeg * Math.PI) / 180;
          const dirX = Math.cos(rad);
          const dirY = Math.sin(rad);
          // Place label well behind the cursor body. The body extends ~28px from
          // the tip in the -dir direction; we add a 6px gap.
          const offsetDist = 34;
          const anchorX = target.x - dirX * offsetDist;
          const anchorY = target.y - dirY * offsetDist;
          // The label's "cursor-facing" edge is the edge closest to the cursor,
          // i.e. the +dir side of the label box. We anchor that edge at (anchorX, anchorY).
          // For most travel angles (downward into the desktop), the cursor sits
          // below/right of the label, so anchor the label's bottom-right corner
          // toward the cursor.
          //
          // To make this work for ANY angle, we shift the label by half its size
          // away from the cursor along the +dir axis. We don't know the label's
          // width in advance, so we approximate by offsetting by a fixed amount
          // (half a typical short label) and let the right side breathe.
          //
          // Simpler approach: keep the label centered at anchor, but make anchor
          // further from cursor based on a generous estimate.
          return (
            <div
              className="absolute whitespace-nowrap text-[10px] font-medium text-white px-2 py-0.5 rounded-md pointer-events-none animate-fadein-label"
              style={{
                background: color,
                left: anchorX,
                top: anchorY,
                // Anchor by the edge facing the cursor: shift the label AWAY from cursor
                // by 50% of its own width AND 50% of its own height along the -dir vector.
                // This pins the label's near-edge at the anchor point.
                transform: `translate(${(-50 - dirX * 50)}%, ${(-50 - dirY * 50)}%)`,
                boxShadow: '0 1px 3px rgba(0,0,0,0.3)',
                zIndex: 29,
              }}
            >
              {label}
            </div>
          );
        })()
      )}
      <style>{`
        @keyframes fadeinLabel-${id} {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        .animate-fadein-label { animation: fadeinLabel-${id} 0.2s ease-out both; }
      `}</style>
    </>
  );
}

function SpawnInputOverlay({ open, onSubmit, onClose }) {
  const [text, setText] = useState('');
  const inputRef = useRef(null);

  useEffect(() => {
    if (open) {
      setText('');
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  }, [open]);

  if (!open) return null;

  const handleKey = (e) => {
    if (e.key === 'Enter' && text.trim()) {
      onSubmit(text.trim());
      setText('');
    } else if (e.key === 'Escape') {
      onClose();
    }
  };

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
          placeholder="Spawn an agent to…"
          className="bg-transparent border-0 outline-none flex-1 text-[12px] text-white placeholder-white/40"
        />
        <button
          onClick={onClose}
          className="text-[9px] text-white/40 hover:text-white/80 px-1.5 py-px border border-white/15 rounded font-mono"
        >
          esc
        </button>
        <button
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

function MacDesktop({ state, activeAgentId, runningIds, hovering, setHovering, spawns, onRequestSpawn, spawnInputOpen, onCloseSpawnInput, desktopRef, desktopSize }) {
  const isExpanded = hovering || state === 'expanded-pinned';
  // Notch sits centered, just below the menu bar
  const notchAnchor = { x: desktopSize.w / 2, y: 24 };

  return (
    <div ref={desktopRef} className="relative w-full overflow-hidden rounded-2xl border border-black/10" style={{ aspectRatio: '16 / 10' }}>
      <div
        className="absolute inset-0"
        style={{
          backgroundImage:
            'radial-gradient(circle at 20% 30%, rgba(120,100,200,0.25) 0%, transparent 50%), radial-gradient(circle at 80% 70%, rgba(80,140,200,0.2) 0%, transparent 50%), linear-gradient(180deg, #2d2a4a 0%, #1a1d29 100%)',
        }}
      />

      <div
        className="absolute top-0 left-0 right-0 h-7 flex items-center px-4 gap-4 text-[11px] text-white/85"
        style={{ background: 'rgba(20,22,30,0.5)', backdropFilter: 'blur(10px)' }}
      >
        <Apple size={13} fill="currentColor" />
        <span className="font-medium">Finder</span>
        <span>File</span>
        <span>Edit</span>
        <span>View</span>
        <span>Go</span>
        <span>Window</span>
        <span>Help</span>
        <div className="ml-auto flex items-center gap-3.5">
          <Wifi size={13} />
          <BatteryFull size={13} />
          <span>Sun 5:02 PM</span>
        </div>
      </div>

      {isExpanded && <div className="absolute inset-0 bg-black/40 z-10 transition-opacity duration-300" />}

      <Notch state={state} activeAgentId={activeAgentId} hovering={hovering} setHovering={setHovering} runningIds={runningIds} />

      {/* Spawned agent cursors */}
      {spawns.map((s) => (
        <SpawnedCursor key={s.id} spawn={s} notchAnchor={notchAnchor} />
      ))}

      {/* New agent input — drops down below the notch */}
      <SpawnInputOverlay open={spawnInputOpen} onSubmit={onRequestSpawn} onClose={onCloseSpawnInput} />

      <div
        className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-2xl px-3 py-1.5 flex gap-2 transition-opacity duration-300"
        style={{
          background: 'rgba(255,255,255,0.15)',
          border: '0.5px solid rgba(255,255,255,0.25)',
          backdropFilter: 'blur(20px) saturate(180%)',
          opacity: isExpanded ? 0.5 : 1,
        }}
      >
        {ALL_AGENT_IDS.map((id) => {
          const a = AGENTS[id];
          const IconC = a.Icon;
          const isRunning = runningIds.includes(id);
          return (
            <div key={id} className="relative">
              <div className="w-8 h-8 rounded-lg flex items-center justify-center" style={{ background: a.color }}>
                <IconC size={16} color="#fff" />
              </div>
              {isRunning && <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1 h-1 rounded-full bg-white" />}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ControlButton({ active, onClick, children, accent }) {
  return (
    <button
      onClick={onClick}
      className="px-3 py-2 text-left rounded-lg transition-all border text-sm flex items-start gap-2.5"
      style={{
        background: active ? '#1a1a1a' : '#fff',
        color: active ? '#fff' : '#1a1a1a',
        borderColor: active ? '#1a1a1a' : '#e5e3dc',
      }}
    >
      {accent && <div className="w-1 self-stretch rounded-full mt-0.5" style={{ background: accent }} />}
      <div className="flex-1">{children}</div>
    </button>
  );
}

// Pool of fun fallback agent identities for spawned cursors
const SPAWN_COLORS = ['#1D9E75', '#EF9F27', '#D4537E', '#378ADD', '#7F77DD', '#E15A47', '#3DB0B5', '#A856C9'];
let SPAWN_COUNTER = 0;

export default function App() {
  const [state, setState] = useState('running-single');
  const [activeAgentId, setActiveAgentId] = useState('coder');
  const [hovering, setHovering] = useState(false);
  const [runningIds, setRunningIds] = useState(['coder']);

  // Spawn machinery
  const [spawns, setSpawns] = useState([]);
  const [spawnInputOpen, setSpawnInputOpen] = useState(false);
  const desktopRef = useRef(null);
  const [desktopSize, setDesktopSize] = useState({ w: 1000, h: 625 });

  useLayoutEffect(() => {
    if (!desktopRef.current) return;
    const ro = new ResizeObserver((entries) => {
      const r = entries[0].contentRect;
      setDesktopSize({ w: r.width, h: r.height });
    });
    ro.observe(desktopRef.current);
    return () => ro.disconnect();
  }, []);

  // Phase choreography per spawn
  // emerge (0.5s) → travel (0.9s) → shake-left (0.35s) → shake-right (0.35s) → working (persistent)
  const advanceSpawn = (id, nextPhase) => {
    setSpawns((curr) => curr.map((s) => (s.id === id ? { ...s, phase: nextPhase } : s)));
  };

  const handleSpawn = (taskText) => {
    const id = `spawn-${++SPAWN_COUNTER}-${Date.now()}`;
    const color = SPAWN_COLORS[SPAWN_COUNTER % SPAWN_COLORS.length];
    const label = taskText.slice(0, 40);

    // Pick a target somewhere on the desktop body (not the menu bar, not the dock)
    const padding = 60;
    const target = {
      x: padding + Math.random() * (desktopSize.w - padding * 2),
      y: 90 + Math.random() * (desktopSize.h - 160),
    };
    const curveSide = Math.random() > 0.5 ? 1 : -1;

    const newSpawn = { id, color, label, target, phase: 'emerge', curveSide, startedAt: Date.now() };
    setSpawns((curr) => [...curr, newSpawn]);
    setSpawnInputOpen(false);

    // Schedule phase transitions
    setTimeout(() => advanceSpawn(id, 'travel'),        500);
    setTimeout(() => advanceSpawn(id, 'shake-left'),    500 + 900);
    setTimeout(() => advanceSpawn(id, 'shake-right'),   500 + 900 + 350);
    setTimeout(() => advanceSpawn(id, 'working'),       500 + 900 + 350 + 350);
  };

  const clearSpawns = () => setSpawns([]);

  useEffect(() => {
    if (state === 'idle') setRunningIds([]);
    else if (state === 'running-single' || state === 'complete' || state === 'needs-input') {
      setRunningIds([activeAgentId]);
    } else if (state === 'running-multi') {
      setRunningIds(['coder', 'browser', 'scheduler']);
    } else if (state === 'expanded-pinned') {
      setRunningIds([activeAgentId]);
    }
  }, [state, activeAgentId]);

  const stateOptions = [
    { id: 'idle',            label: 'Idle',              desc: 'Nothing running' },
    { id: 'running-single',  label: 'Running (single)',  desc: 'One agent active',     accent: AGENTS[activeAgentId].color },
    { id: 'running-multi',   label: 'Running (multi)',   desc: '3 agents in parallel' },
    { id: 'complete',        label: 'Task complete',     desc: 'Bulge + check',        accent: AGENTS[activeAgentId].color },
    { id: 'needs-input',     label: 'Needs your input',  desc: 'Pulsing · persistent', accent: AGENTS[activeAgentId].color },
    { id: 'expanded-pinned', label: 'Expanded (pinned)', desc: 'Force-open the panel' },
  ];

  return (
    <div style={{ background: '#f5f3ee', minHeight: '100vh' }} className="px-6 py-10">
      <div className="max-w-[1280px] mx-auto">
        <header className="mb-10">
        </header>

        <div className="mb-8">
          <MacDesktop
            state={state}
            activeAgentId={activeAgentId}
            runningIds={runningIds}
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
              onClick={() => setSpawnInputOpen((v) => !v)}
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md border border-[#e5e3dc] bg-white hover:bg-gray-50 text-gray-700 transition"
            >
              <Plus size={12} />
              <span className="text-[11px] font-medium">New agent</span>
              <span className="text-[9px] text-gray-400 font-mono ml-1">↵ to spawn</span>
            </button>
            {spawns.length > 0 && (
              <button
                onClick={clearSpawns}
                className="text-[11px] text-gray-500 hover:text-gray-800 underline underline-offset-2"
              >
                clear {spawns.length} spawned
              </button>
            )}
            <span className="text-gray-400">·</span>
            <span>{hovering ? 'move away to collapse' : 'hover the notch to expand'}</span>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="bg-white rounded-xl border p-5" style={{ borderColor: '#e5e3dc' }}>
            <div className="flex items-center justify-between mb-4">
              <div>
                <h2 className="font-medium text-[15px]">Notch state</h2>
                <p className="text-xs text-gray-500 mt-0.5">Click to switch states</p>
              </div>
              <div className="font-mono text-[10px] text-gray-400 uppercase tracking-wider">{state}</div>
            </div>
            <div className="grid grid-cols-2 gap-2">
              {stateOptions.map((opt) => (
                <ControlButton key={opt.id} active={state === opt.id} onClick={() => setState(opt.id)} accent={opt.accent}>
                  <div className="font-medium text-[13px]">{opt.label}</div>
                  <div className="text-[11px] opacity-60 mt-0.5">{opt.desc}</div>
                </ControlButton>
              ))}
            </div>
          </div>

          <div className="bg-white rounded-xl border p-5" style={{ borderColor: '#e5e3dc' }}>
            <div className="flex items-center justify-between mb-4">
              <div>
                <h2 className="font-medium text-[15px]">Active agent</h2>
                <p className="text-xs text-gray-500 mt-0.5">Drives the color & message</p>
              </div>
              <div className="font-mono text-[10px] text-gray-400 uppercase tracking-wider">{activeAgentId}</div>
            </div>
            <div className="grid grid-cols-1 gap-1.5">
              {ALL_AGENT_IDS.map((id) => {
                const a = AGENTS[id];
                const IconC = a.Icon;
                const isSelected = activeAgentId === id;
                return (
                  <button
                    key={id}
                    onClick={() => setActiveAgentId(id)}
                    className="px-2.5 py-2 rounded-lg flex items-center gap-2.5 transition-all border"
                    style={{
                      background: isSelected ? '#fafaf6' : '#fff',
                      borderColor: isSelected ? a.color : '#e5e3dc',
                    }}
                  >
                    <div className="w-6 h-6 rounded-md flex items-center justify-center flex-shrink-0" style={{ background: a.color }}>
                      <IconC size={12} color="#fff" />
                    </div>
                    <div className="flex-1 text-left min-w-0">
                      <div className="text-[12px] font-medium">{a.name}</div>
                      <div className="text-[10px] text-gray-500 truncate">{a.subtitle}</div>
                    </div>
                    {isSelected && <Check size={14} color={a.color} />}
                  </button>
                );
              })}
            </div>
          </div>
        </div>

        <div className="mt-10 pt-6 border-t border-gray-200 grid grid-cols-1 md:grid-cols-3 gap-6 text-[13px] text-gray-600">
          <div>
            <div className="font-medium text-gray-900 mb-1">Resting</div>
            <p className="leading-relaxed">Small pill, agent color + live activity bars. Doesn't compete with your work.</p>
          </div>
          <div>
            <div className="font-medium text-gray-900 mb-1">Attention</div>
            <p className="leading-relaxed">Bulges with the agent's color. Check badge = done. Pulsing pink halo = needs you.</p>
          </div>
          <div>
            <div className="font-medium text-gray-900 mb-1">Expanded</div>
            <p className="leading-relaxed">Full roster, statuses, ⌘K to dispatch. Background dims so focus stays on Donkey.</p>
          </div>
        </div>
      </div>
    </div>
  );
}

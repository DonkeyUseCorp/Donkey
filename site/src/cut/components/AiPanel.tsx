"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport, type ChatTransport, type UIMessage } from "ai";
import {
  ArrowUp,
  Check,
  ChevronDown,
  CircleDashed,
  Copy,
  Ellipsis,
  ExternalLink,
  FolderPlus,
  History,
  Plus,
  Sparkles,
  Square,
  Star,
  Trash2,
  TriangleAlert,
  Wrench,
  X,
} from "lucide-react";
import Markdown from "react-markdown";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { apiFetch, engineReady } from "@/cut/lib/api";
import { buildAiContext } from "@/cut/lib/aiContext";
import { runAiTool } from "@/cut/lib/aiTools";
import { setAssetDragData } from "@/cut/lib/assetDrag";
import {
  addRefOnce,
  collectRefs,
  normalizeRef,
  sameRef,
  setRefDragData,
  splitMentions,
  useRefCandidates,
  useAssetDrop,
  type AssetRef,
} from "@/cut/lib/assetRef";
import { signInUrl, useSignedIn } from "@/cut/lib/generate";
import { streamGeminiChat } from "@/cut/lib/geminiChat";
import { AI_MODELS } from "@/cut/lib/aiModels";
import { saveAssetToLibrary } from "@/cut/lib/library";
import { revealRef } from "@/cut/lib/refReveal";
import { useEditor } from "@/cut/lib/store";
import { cn } from "@/lib/utils";
import { MentionTextarea, RefChips, RefThumb, RefTokenChip } from "./AssetRefs";

// Chat attachments are asset refs — anything in the project, the library, or
// the stock catalog. They arrive by drag (media cards, library clips, stock
// tiles, timeline clips, the preview) or as @name mentions in the message.

interface ModelsInfo {
  providers: Record<string, { available: boolean; note: string }>;
}

/** A saved chat thread, persisted per project in localStorage. */
interface ChatThread {
  id: string;
  title: string;
  updatedAt: number;
  messages: UIMessage[];
  /** Provider-native session ids so a resumed thread keeps its context. */
  sessions: Record<string, string>;
}

const THREAD_LIMIT = 30;
const threadsKey = () => `cut-ai-threads-${useEditor.getState().projectId ?? "global"}`;

function readThreads(): ChatThread[] {
  try {
    const v = JSON.parse(localStorage.getItem(threadsKey()) ?? "[]") as unknown;
    return Array.isArray(v) ? (v as ChatThread[]) : [];
  } catch {
    return [];
  }
}

function writeThreads(list: ChatThread[]) {
  try {
    localStorage.setItem(threadsKey(), JSON.stringify(list.slice(0, THREAD_LIMIT)));
  } catch {
    // Storage full/blocked — history just won't persist.
  }
}

const MODEL_KEY = "cut-ai-model";
const FAVS_KEY = "cut-ai-favs";
const PROVIDER_LABEL: Record<string, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini",
  test: "Testing",
};

const SUGGESTIONS = [
  "What's in this video?",
  "Add transitions between clips",
  "Improve my title",
  "Watch and create subtitles",
  "Rewrite subtitles for social",
  "Write my post caption + tags",
];

/** Chat provider bucket for a model id. */
const provider = (id: string): string =>
  id.startsWith("claude")
    ? "claude"
    : id.startsWith("gemini")
      ? "gemini"
      : id === "cut-test"
        ? "test"
        : "codex";

export function AiPanel({ onClose }: { onClose: () => void }) {
  const [info, setInfo] = useState<ModelsInfo | null>(null);
  const signedIn = useSignedIn();
  const [model, setModel] = useState<string>(() =>
    typeof window === "undefined" ? "claude-fable-5" : localStorage.getItem(MODEL_KEY) ?? "claude-fable-5"
  );
  // One chat is active at a time; every past chat lives in the Threads panel.
  const [activeChat, setActiveChat] = useState<string>(() => crypto.randomUUID());
  const [historyOpen, setHistoryOpen] = useState(false);
  const [threads, setThreads] = useState<ChatThread[]>([]);

  useEffect(() => {
    let alive = true;
    void apiFetch("/api/cut/ai/models")
      .then((r) => r.json())
      .then((d: ModelsInfo) => alive && setInfo(d))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  const newChat = () => {
    setActiveChat(crypto.randomUUID());
    setHistoryOpen(false);
  };

  const openThread = (t: ChatThread) => {
    setActiveChat(t.id);
    setHistoryOpen(false);
  };

  const toggleHistory = () => {
    if (!historyOpen) setThreads(readThreads());
    setHistoryOpen((v) => !v);
  };

  const deleteThread = (id: string) => {
    writeThreads(readThreads().filter((t) => t.id !== id));
    setThreads((p) => p.filter((t) => t.id !== id));
    // If the open chat was deleted, start a fresh one so it can't re-save
    // itself on the next message and resurrect the thread.
    if (activeChat === id) setActiveChat(crypto.randomUUID());
  };

  const selectModel = (id: string) => {
    setModel(id);
    localStorage.setItem(MODEL_KEY, id);
  };

  // Gemini runs on the user's Donkey account, so its availability is the
  // sign-in probe, not the engine's CLI checks. Signed-in state (or a probe
  // still in flight) leaves it usable; a definite signed-out disables it.
  const mergedInfo = useMemo<ModelsInfo | null>(() => {
    if (!info) return null;
    return {
      ...info,
      providers: {
        ...info.providers,
        gemini:
          signedIn === false
            ? { available: false, note: "sign in to Donkey to chat" }
            : (info.providers.gemini ?? { available: true, note: "" }),
      },
    };
  }, [info, signedIn]);

  return (
    <aside className="ai-panel relative flex min-h-0 w-[340px] shrink-0 animate-in flex-col border-l border-border bg-card duration-300 ease-out slide-in-from-right-full">
      <div className="flex h-[46px] shrink-0 items-center gap-1.5 border-b border-border pr-2 pl-3.5">
        <Sparkles className="size-4 text-[#0a84ff]" />
        <div className="flex-1" />
        <Button
          variant="ghost"
          size="sm"
          className="ai-threads"
          title="Past threads"
          aria-pressed={historyOpen}
          onClick={toggleHistory}
        >
          <History />
        </Button>
        <Button
          variant="ghost"
          size="sm"
          className="ai-new-thread"
          title="New chat"
          onClick={newChat}
        >
          <Plus />
        </Button>
        <Button variant="ghost" size="sm" title="Close (⌘J)" onClick={onClose}>
          <X />
        </Button>
      </div>

      {historyOpen && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setHistoryOpen(false)} />
          <div className="ai-thread-list absolute top-0 right-full bottom-0 z-40 flex w-[280px] animate-in flex-col border-x border-border bg-card shadow-[-16px_0_40px_rgba(0,0,0,0.14)] duration-200 ease-out fade-in-0 slide-in-from-right-6">
            <div className="flex h-[46px] shrink-0 items-center justify-between border-b border-border pr-2 pl-3.5">
              <span className="text-sm font-semibold tracking-tight">Threads</span>
              <Button variant="ghost" size="sm" title="Close" onClick={() => setHistoryOpen(false)}>
                <X />
              </Button>
            </div>
            <div className="ai-thread-items flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto p-2">
              {threads.length === 0 ? (
                <p className="px-2 py-3 text-[11.5px] leading-relaxed text-muted-foreground">
                  No past threads yet.
                </p>
              ) : (
                threads.map((t) => (
                  <button
                    key={t.id}
                    className="group relative flex w-full flex-col gap-0.5 rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-muted"
                    onClick={() => openThread(t)}
                  >
                    <span className="w-full truncate pr-6 text-[12px] font-medium">{t.title}</span>
                    <span className="text-[10.5px] text-muted-foreground">
                      {new Date(t.updatedAt).toLocaleString([], {
                        month: "short",
                        day: "numeric",
                        hour: "numeric",
                        minute: "2-digit",
                      })}
                    </span>
                    <span
                      role="button"
                      aria-label="Delete thread"
                      title="Delete thread"
                      className="absolute top-1/2 right-1.5 grid size-6 -translate-y-1/2 place-items-center rounded-md text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:bg-black/10 hover:text-red-600"
                      onClick={(e) => {
                        e.stopPropagation();
                        deleteThread(t.id);
                      }}
                    >
                      <Trash2 className="size-3.5" />
                    </span>
                  </button>
                ))
              )}
            </div>
          </div>
        </>
      )}

      <ChatSession
        key={activeChat}
        threadId={activeChat}
        info={mergedInfo}
        model={model}
        onModelChange={selectModel}
      />
    </aside>
  );
}

/** One chat with the agent. Remounts per active thread; its messages and
 * provider session are restored from the saved thread on open. */
function ChatSession({
  threadId,
  info,
  model,
  onModelChange,
}: {
  threadId: string;
  info: ModelsInfo | null;
  model: string;
  onModelChange: (id: string) => void;
}) {
  const [input, setInput] = useState("");
  const [attachments, setAttachments] = useState<AssetRef[]>([]);
  const candidates = useRefCandidates();
  const { active: dropActive, attachTarget, targetProps } = useAssetDrop((ref) => setAttachments((prev) => addRefOnce(prev, ref)));
  const sessionKeyRef = useRef<string | null>(null);
  // Resume from the saved thread when this id exists in history.
  const [initialThread] = useState<ChatThread | undefined>(() =>
    typeof window === "undefined" ? undefined : readThreads().find((t) => t.id === threadId)
  );
  const providerSessions = useRef<Record<string, string>>({ ...(initialThread?.sessions ?? {}) });
  const modelRef = useRef(model);
  modelRef.current = model;

  // Gemini turns run their editor tools inside the transport loop (no engine
  // bridge); this flags them so onToolCall doesn't execute those calls again.
  const clientToolsRef = useRef(false);
  const transport = useMemo<ChatTransport<UIMessage>>(() => {
    const engine = new DefaultChatTransport<UIMessage>({
      // The engine origin is discovered asynchronously; await it per request
      // (not at mount) so an early send still targets the local engine rather
      // than the hosted origin, where the Cut APIs 404. engineReady memoizes,
      // so only the first request pays for discovery.
      prepareSendMessagesRequest: async ({ messages }) => ({
        api: `${await engineReady()}/api/cut/ai/chat`,
        body: {
          messages,
          model: modelRef.current,
          context: buildAiContext(),
          providerSession: providerSessions.current[provider(modelRef.current)],
        },
      }),
    });
    return {
      // Claude/Codex chat through the local engine; Gemini goes straight from
      // the page to Donkey's hosted inference with the user's session.
      sendMessages: async (options) => {
        if (provider(modelRef.current) === "gemini") {
          clientToolsRef.current = true;
          return streamGeminiChat({
            model: modelRef.current,
            messages: options.messages,
            abortSignal: options.abortSignal,
          });
        }
        clientToolsRef.current = false;
        return engine.sendMessages(options);
      },
      reconnectToStream: (options) => engine.reconnectToStream(options),
    };
  }, []);

  const { messages, sendMessage, stop, status, error, clearError } = useChat({
    id: threadId,
    messages: initialThread?.messages,
    transport,
    onData: (part) => {
      if (part.type === "data-session") {
        const d = part.data as { sessionKey?: string; providerSession?: string };
        if (d.sessionKey) sessionKeyRef.current = d.sessionKey;
        if (d.providerSession) providerSessions.current[provider(modelRef.current)] = d.providerSession;
      }
    },
    onToolCall: ({ toolCall }) => {
      // Gemini turns already executed the tool in the transport loop; their
      // tool chunks are display-only.
      if (clientToolsRef.current) return;
      // Execute on the editor store, then hand the result back to the
      // server-side bridge (which is holding the provider's tool call open).
      void (async () => {
        const post = (payload: Record<string, unknown>) =>
          apiFetch("/api/cut/ai/tool-result", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              sessionKey: sessionKeyRef.current,
              toolCallId: toolCall.toolCallId,
              ...payload,
            }),
          });
        try {
          const output = await runAiTool(
            toolCall.toolName,
            (toolCall.input ?? {}) as Record<string, unknown>
          );
          await post({ output });
        } catch (err) {
          await post({ errorText: err instanceof Error ? err.message : String(err) });
        }
      })();
    },
  });

  const busy = status === "submitted" || status === "streaming";

  // Coalesce every edit the assistant makes in one turn into a single undo
  // step, so ⌘Z reverts the whole turn rather than one tool call at a time.
  useEffect(() => {
    if (!busy) return;
    useEditor.getState().beginHistoryBatch();
    return () => useEditor.getState().endHistoryBatch();
  }, [busy]);

  // Keep the thread saved (so it shows up in the Threads panel) as it grows.
  useEffect(() => {
    if (messages.length === 0) return;
    const firstUser = messages.find((m) => m.role === "user");
    const title =
      firstUser?.parts
        .map((p) => (p.type === "text" ? p.text : ""))
        .join("")
        .trim()
        .slice(0, 80) || "New chat";
    const rest = readThreads().filter((t) => t.id !== threadId);
    writeThreads([
      {
        id: threadId,
        title,
        updatedAt: Date.now(),
        messages,
        sessions: { ...providerSessions.current },
      },
      ...rest,
    ]);
  }, [messages, threadId]);

  const scrollRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, busy]);

  const send = (text: string) => {
    // Inline @mentions attach their assets alongside the dropped chips. The
    // message keeps the raw tokens — they render as interactive chips and the
    // model reads the handle↔asset mapping from <attached_assets>.
    const body = text.trim();
    const { refs: all } = collectRefs(body, attachments, candidates);
    if ((!body && all.length === 0) || busy || !currentAvailable) return;
    clearError();
    void sendMessage({
      text: body,
      ...(all.length > 0 && { metadata: { attachments: all } }),
    });
    setInput("");
    setAttachments([]);
  };

  const currentAvailable = info ? info.providers[provider(model)]?.available !== false : true;

  return (
    <div
      ref={attachTarget}
      {...targetProps}
      className="relative flex min-h-0 flex-1 flex-col"
    >
      <div ref={scrollRef} className="ai-messages min-h-0 flex-1 overflow-y-auto px-3.5 py-3">
        {messages.length === 0 && (
          <div className="flex flex-col gap-3 pt-6">
            <p className="text-[12.5px] leading-relaxed text-muted-foreground">
              I can see your whole project — clips, titles, subtitles, publish
              metadata — and edit it for you. Select something and tell me what
              to change, or ask anything about the cut.
            </p>
            <div className="flex flex-wrap gap-1.5">
              {SUGGESTIONS.map((sug) => (
                <button
                  key={sug}
                  className="ai-suggestion rounded-full border border-border px-2.5 py-1 text-[11.5px] text-muted-foreground transition-colors hover:border-input hover:text-foreground"
                  onClick={() => send(sug)}
                >
                  {sug}
                </button>
              ))}
            </div>
          </div>
        )}
        {messages.map((m) => (
          <MessageView key={m.id} message={m} />
        ))}
        {busy && (
          <div className="ai-busy mt-1 flex items-center gap-1.5 text-[11.5px] text-muted-foreground">
            <CircleDashed className="size-3 animate-spin" /> Working…
          </div>
        )}
        {error && (
          <div className="ai-error mt-2 flex items-start gap-2 rounded-lg bg-red-50 px-2.5 py-2 text-[11.5px] leading-relaxed text-red-700">
            <TriangleAlert className="mt-0.5 size-3.5 shrink-0" />
            {error.message}
          </div>
        )}
      </div>

      <div className="shrink-0 border-t border-border p-2.5">
        <div
          className={cn(
            "rounded-xl border bg-background transition-colors",
            dropActive
              ? "border-[#0a84ff] ring-2 ring-[#0a84ff]/30"
              : "border-input focus-within:border-ring"
          )}
        >
          {dropActive && (
            <div className="px-3 pt-2 text-[11.5px] font-medium text-[#0a84ff]">
              Drop to attach
            </div>
          )}
          <RefChips
            refs={attachments}
            onRemove={(ref) => setAttachments((p) => p.filter((x) => !sameRef(x, ref)))}
            className="px-2.5 pt-2.5"
          />
          <MentionTextarea
            className="ai-input max-h-40 min-h-[38px] w-full resize-none bg-transparent px-3 pt-2 text-[12.5px] leading-relaxed outline-none placeholder:text-muted-foreground/70"
            rows={2}
            placeholder="Ask about your video, or tell me what to change… @ references media"
            value={input}
            onChange={setInput}
            candidates={candidates}
            submitKey="enter"
            menuSide="top"
            onSubmit={() => send(input)}
          />
          <div className="flex items-center gap-1 px-1.5 pb-1.5">
            <ModelSelector info={info} model={model} onSelect={onModelChange} />
            <div className="flex-1" />
            {busy ? (
              <Button variant="outline" size="sm" className="ai-stop" title="Stop" onClick={() => void stop()}>
                <Square className="size-3" />
              </Button>
            ) : (
              <Button
                size="sm"
                className="ai-send"
                title="Send (Enter)"
                disabled={(!input.trim() && attachments.length === 0) || !currentAvailable}
                onClick={() => send(input)}
              >
                <ArrowUp className="size-3.5" />
              </Button>
            )}
          </div>
        </div>
        {info && !currentAvailable && (
          provider(model) === "gemini" ? (
            <p className="ai-provider-note mt-1.5 px-1 text-[10.5px] leading-relaxed text-muted-foreground">
              Gemini chats on your Donkey account.{" "}
              <a
                className="font-medium text-blue-600 hover:underline dark:text-blue-400"
                href={signInUrl()}
              >
                Sign in
              </a>{" "}
              to continue.
            </p>
          ) : (
            <p className="ai-provider-note mt-1.5 px-1 text-[10.5px] leading-relaxed text-amber-700">
              {PROVIDER_LABEL[provider(model)]}: {info.providers[provider(model)]?.note}
            </p>
          )
        )}
      </div>
    </div>
  );
}

/** Asset card inside a sent message — click to jump back to the original
 * asset, drag onto the timeline, "…" menu for more actions. */
function MessageAssetCard({ asset }: { asset: AssetRef }) {
  return (
    <div className="ai-msg-asset group relative w-16">
      <button
        className="flex w-full flex-col gap-1 text-left"
        title={`${asset.name} — click to show · drag to the timeline`}
        draggable
        onDragStart={(e) => {
          // Project assets keep the timeline-placement payload; the ref rides
          // along either way (chat, creators), from the card's own data so it
          // survives the asset leaving the project.
          if (asset.scope === "project") setAssetDragData(e, asset.id);
          setRefDragData(e, asset);
        }}
        onClick={() => revealRef(asset)}
      >
        <RefThumb item={asset} className="size-16 transition-colors group-hover:border-input" />
        <span className="w-full truncate text-[10px] text-muted-foreground">{asset.name}</span>
      </button>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <button
              aria-label="Asset options"
              className="absolute top-1 right-1 grid size-5 place-items-center rounded-md bg-black/55 text-white opacity-0 transition-opacity group-hover:opacity-100 hover:bg-black/75"
            />
          }
        >
          <Ellipsis className="size-3" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" className="w-40">
          <DropdownMenuItem onClick={() => window.open(asset.url, "_blank", "noopener")}>
            <ExternalLink /> Open file
          </DropdownMenuItem>
          {asset.scope === "project" && (
            <DropdownMenuItem
              onClick={() => {
                const s = useEditor.getState();
                const full = s.assets.find((a) => a.id === asset.id);
                if (!full || !s.projectId) return;
                void saveAssetToLibrary(s.projectId, full).catch(() => {
                  // Library write failed; nothing to roll back.
                });
              }}
            >
              <FolderPlus /> Add to library
            </DropdownMenuItem>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}

/** User-message text with resolved `@` mentions rendered as interactive token
 * chips. Tokens resolve against the message's own attachments first (they hold
 * what was meant at send time), then the live candidates. */
function MentionedText({ text, attachments }: { text: string; attachments: AssetRef[] }) {
  const candidates = useRefCandidates();
  const parts = useMemo(
    () => splitMentions(text, [...attachments, ...candidates]),
    [text, attachments, candidates]
  );
  return (
    <>
      {parts.map((p, i) =>
        typeof p === "string" ? (
          <span key={i}>{p}</span>
        ) : (
          <RefTokenChip key={i} item={p} onDark />
        )
      )}
    </>
  );
}

/** Copy-to-clipboard affordance revealed on message hover. */
function MessageCopy({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  if (!text) return null;
  return (
    <button
      aria-label="Copy message"
      title="Copy"
      className="ai-msg-copy grid size-6 place-items-center rounded-md text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:bg-muted hover:text-foreground"
      onClick={() => {
        void navigator.clipboard.writeText(text).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        });
      }}
    >
      {copied ? <Check className="size-3.5 text-emerald-600" /> : <Copy className="size-3.5" />}
    </button>
  );
}

function MessageView({ message }: { message: UIMessage }) {
  if (message.role === "user") {
    const text = message.parts.map((p) => (p.type === "text" ? p.text : "")).join("");
    // normalizeRef also reads attachments saved by older threads (pre-ref shape).
    const attachments = ((message.metadata as { attachments?: unknown[] } | undefined)
      ?.attachments ?? [])
      .map(normalizeRef)
      .filter((r): r is AssetRef => r !== null);
    return (
      <div className="ai-msg-user group mb-3 flex flex-col items-end gap-1">
        {attachments.length > 0 && (
          <div className="flex max-w-[85%] flex-wrap justify-end gap-1.5">
            {attachments.map((a) => (
              <MessageAssetCard key={`${a.scope}:${a.id}`} asset={a} />
            ))}
          </div>
        )}
        {text && (
          <div className="max-w-[85%] rounded-2xl rounded-br-md bg-neutral-900 px-3 py-2 text-[12.5px] leading-relaxed whitespace-pre-wrap text-white">
            <MentionedText text={text} attachments={attachments} />
          </div>
        )}
        <MessageCopy text={text} />
      </div>
    );
  }
  const text = message.parts.map((p) => (p.type === "text" ? p.text : "")).join("");
  return (
    <div className="ai-msg-assistant group mb-3 flex flex-col gap-1.5">
      {message.parts.map((part, i) => {
        if (part.type === "text") {
          return (
            <div key={i} className="ai-md max-w-full text-[12.5px] leading-relaxed">
              <Markdown
                components={{
                  p: (p) => <p className="mb-1.5 last:mb-0" {...p} />,
                  ul: (p) => <ul className="mb-1.5 list-disc pl-4 last:mb-0" {...p} />,
                  ol: (p) => <ol className="mb-1.5 list-decimal pl-4 last:mb-0" {...p} />,
                  li: (p) => <li className="mb-0.5" {...p} />,
                  code: (p) => (
                    <code className="rounded bg-muted px-1 py-px font-mono text-[11px]" {...p} />
                  ),
                  a: (p) => <a className="text-[#0a84ff] underline" target="_blank" {...p} />,
                }}
              >
                {part.text}
              </Markdown>
            </div>
          );
        }
        if (part.type.startsWith("tool-") || part.type === "dynamic-tool") {
          const p = part as unknown as {
            type: string;
            toolName?: string;
            state: string;
            input?: unknown;
            output?: unknown;
            errorText?: string;
          };
          const name = p.toolName ?? part.type.slice(5);
          const failed = p.state === "output-error";
          const done = p.state === "output-available";
          return (
            <details key={i} className="ai-tool group max-w-full">
              <summary
                className={cn(
                  "flex cursor-pointer list-none items-center gap-1.5 rounded-md border border-border px-2 py-1 text-[11px] text-muted-foreground transition-colors select-none hover:bg-muted/60 [&::-webkit-details-marker]:hidden",
                  failed && "border-red-200 text-red-700"
                )}
              >
                <Wrench className="size-3 shrink-0" />
                <span className="font-mono">{name}</span>
                {done && <Check className="size-3 text-emerald-600" />}
                {failed && <TriangleAlert className="size-3" />}
                {!done && !failed && <CircleDashed className="size-3 animate-spin" />}
              </summary>
              <pre className="mt-1 max-h-40 overflow-auto rounded-md bg-muted/70 p-2 font-mono text-[10px] leading-relaxed whitespace-pre-wrap">
                {JSON.stringify({ input: p.input, output: p.output, error: p.errorText }, null, 2)}
              </pre>
            </details>
          );
        }
        return null;
      })}
      <MessageCopy text={text} />
    </div>
  );
}

function ModelSelector({
  info,
  model,
  onSelect,
}: {
  info: ModelsInfo | null;
  model: string;
  onSelect: (id: string) => void;
}) {
  const [favs, setFavs] = useState<string[]>(() => {
    if (typeof window === "undefined") return [];
    try {
      return JSON.parse(localStorage.getItem(FAVS_KEY) ?? "[]") as string[];
    } catch {
      return [];
    }
  });
  const showTest = typeof window !== "undefined" && localStorage.getItem("cut-ai-test") === "1";
  const models = AI_MODELS.filter((m) => !m.hidden || showTest);
  const groups = ["claude", "codex", "gemini", ...(showTest ? ["test"] : [])].map((p) => ({
    provider: p,
    models: models.filter((m) => m.provider === p),
    available: info?.providers[p]?.available ?? true,
    note: info?.providers[p]?.note ?? "",
  }));
  const flat = groups.flatMap((group) => group.models);
  const currentLabel = models.find((m) => m.id === model)?.label ?? model;

  const toggleFav = (id: string) => {
    const next = favs.includes(id) ? favs.filter((f) => f !== id) : [...favs, id];
    setFavs(next);
    localStorage.setItem(FAVS_KEY, JSON.stringify(next));
  };

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        className="ai-model-trigger flex items-center gap-1 rounded-md px-1.5 py-1 text-[11px] font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
      >
        <Sparkles className="size-3" />
        {currentLabel}
        <ChevronDown className="size-3" />
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="start"
        className="ai-model-menu w-60"
        onKeyDown={(e) => {
          const n = Number(e.key);
          if (n >= 1 && n <= flat.length) onSelect(flat[n - 1].id);
        }}
      >
        {groups.map((group, gi) =>
          group.models.length === 0 ? null : (
            <DropdownMenuGroup key={group.provider}>
              {gi > 0 && <DropdownMenuSeparator />}
              <DropdownMenuLabel className="flex items-center gap-1.5 text-[10.5px] tracking-wider text-muted-foreground uppercase">
                <Sparkles className="size-3" /> {PROVIDER_LABEL[group.provider]}
                {!group.available && (
                  <span className="ml-1 font-normal normal-case text-amber-700">· {group.note}</span>
                )}
              </DropdownMenuLabel>
              {group.models.map((m) => (
                <DropdownMenuItem
                  key={m.id}
                  disabled={!group.available}
                  className="ai-model-item gap-2"
                  onClick={() => onSelect(m.id)}
                >
                  <span className="flex-1 text-[12px]">{m.label}</span>
                  {model === m.id && <Check className="size-3.5 text-[#0a84ff]" />}
                  <button
                    className="rounded p-0.5 hover:bg-muted"
                    title={favs.includes(m.id) ? "Unfavorite" : "Favorite"}
                    onClick={(e) => {
                      e.stopPropagation();
                      e.preventDefault();
                      toggleFav(m.id);
                    }}
                  >
                    <Star
                      className={cn(
                        "size-3",
                        favs.includes(m.id) ? "fill-amber-400 text-amber-400" : "text-muted-foreground/50"
                      )}
                    />
                  </button>
                  <span className="w-3 text-right font-mono text-[10px] text-muted-foreground/60">
                    {flat.indexOf(m) + 1}
                  </span>
                </DropdownMenuItem>
              ))}
            </DropdownMenuGroup>
          )
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

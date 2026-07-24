// Cloud storage for the chat panel's per-project AI threads. The client owns
// the thread shape (id, title, updatedAt, messages, sessions) and mirrors it in
// localStorage for synchronous reads; these routes are the account copy that
// follows the user across browsers. Last write wins per thread — the panel
// pushes the whole thread after each turn.
import type { Prisma } from "@/generated/prisma/client";
import { prisma } from "@/lib/prisma";
import { getProject } from "./projects";
import { caught, err } from "./util";

// A thread is bounded client-side by localStorage (frame payloads stripped
// before save); this bound only rejects a client gone wrong.
const MAX_THREAD_BYTES = 4_000_000;

// Client thread ids come from crypto.randomUUID().
const THREAD_ID = /^[0-9a-fA-F-]{1,64}$/;

type ThreadBody = {
  id: string;
  title: string;
  updatedAt: number;
  messages: unknown[];
  sessions: Record<string, string>;
};

function parseThread(raw: unknown): ThreadBody | null {
  if (!raw || typeof raw !== "object") return null;
  const t = raw as Record<string, unknown>;
  if (typeof t.id !== "string" || !THREAD_ID.test(t.id)) return null;
  if (typeof t.title !== "string" || typeof t.updatedAt !== "number") return null;
  if (!Array.isArray(t.messages)) return null;
  const sessions = t.sessions;
  if (!sessions || typeof sessions !== "object" || Array.isArray(sessions)) return null;
  if (Object.values(sessions).some((v) => typeof v !== "string")) return null;
  return t as ThreadBody;
}

const toClient = (row: {
  id: string;
  title: string;
  updatedAt: Date;
  messages: unknown;
  sessions: unknown;
}) => ({
  id: row.id,
  title: row.title,
  updatedAt: row.updatedAt.getTime(),
  messages: row.messages,
  sessions: row.sessions,
});

export const chatsCloud = {
  /** Every saved thread in a project, newest first — the panel's Threads list. */
  async list(userId: string, projectId: string) {
    if (!(await getProject(userId, projectId))) return err("Project not found.", 404);
    const rows = await prisma.cutChatThread.findMany({
      where: { userId, projectId },
      orderBy: { updatedAt: "desc" },
    });
    return Response.json(rows.map(toClient));
  },

  /** Upsert one thread. The row id is the client's uuid, so ownership is
   * checked against any existing row before writing — a colliding id owned by
   * another user or project reads as not-found rather than being clobbered. */
  async put(userId: string, projectId: string, chatId: string, req: Request) {
    try {
      const text = await req.text();
      if (text.length > MAX_THREAD_BYTES) return err("Thread too large.", 413);
      const body = parseThread(JSON.parse(text));
      if (!body || body.id !== chatId) return err("Invalid thread.", 400);
      if (!(await getProject(userId, projectId))) return err("Project not found.", 404);
      const existing = await prisma.cutChatThread.findUnique({ where: { id: chatId } });
      if (existing && (existing.userId !== userId || existing.projectId !== projectId)) {
        return err("Thread not found.", 404);
      }
      const data = {
        title: body.title,
        updatedAt: new Date(body.updatedAt),
        messages: body.messages as Prisma.InputJsonValue,
        sessions: body.sessions as Prisma.InputJsonValue,
      };
      await prisma.cutChatThread.upsert({
        where: { id: chatId },
        update: data,
        create: { id: chatId, userId, projectId, ...data },
      });
      return Response.json({ ok: true });
    } catch (e) {
      return caught(e, "Could not save thread.");
    }
  },

  async remove(userId: string, projectId: string, chatId: string) {
    await prisma.cutChatThread.deleteMany({ where: { id: chatId, userId, projectId } });
    return Response.json({ ok: true });
  },
};

"use client";

import type { UIMessage, UIMessageChunk } from "ai";
import { AI_SKILL_INDEX, AI_SKILLS, AI_TOOLS, systemPrompt } from "@/cut/server/ai/catalog";
import { buildAiContext } from "./aiContext";
import { runAiTool } from "./aiTools";
import { hostedPost, useGenerate } from "./generate";

// Gemini chat runs from the page through Donkey's hosted Responses route with
// the user's sign-in and credits — the local engine is not involved (same
// carve-out as AI media generation). Each round the model answers or asks for
// editor tools; tools execute right here against the live store via runAiTool,
// and their results go back until the model settles on a reply. The whole
// conversation is replayed per turn, so no provider session is kept.

const MAX_TOOL_ROUNDS = 16;

type Item = Record<string, unknown>;

const toolDeclarations = () =>
  AI_TOOLS.map((t) => ({
    type: "function",
    name: t.name,
    description: t.description,
    parameters: t.inputSchema,
  }));

/** The conversation replayed as hosted-Responses input items. Only text (and
 * attachment refs) from past turns — tool traffic stays within its own turn.
 * The fresh editor snapshot rides on the newest user message alone. */
function inputFromMessages(messages: UIMessage[]): Item[] {
  const lastUser = messages.findLast((m) => m.role === "user");
  const items: Item[] = [];
  for (const m of messages) {
    let text = m.parts
      .map((p) => (p.type === "text" ? p.text : ""))
      .join("")
      .trim();
    if (m.role === "user") {
      const meta = (m.metadata as { attachments?: unknown[] } | undefined)?.attachments;
      if (Array.isArray(meta) && meta.length > 0) {
        text += `\n\n<attached_assets>\nThe user attached these media assets to this message; their text may cite one by @handle or @name. Assets with scope "project" are in the open project (ids usable with the editor tools); "library" and "stock" assets live outside it until imported:\n${JSON.stringify(meta)}\n</attached_assets>`;
      }
      if (m === lastUser) {
        text += `\n\n<editor_state>\n${JSON.stringify(buildAiContext())}\n</editor_state>`;
      }
    }
    if (!text) continue;
    items.push({ role: m.role === "user" ? "user" : "assistant", content: [{ text }] });
  }
  return items;
}

async function requestError(res: Response): Promise<string> {
  if (res.status === 401) {
    // Refresh the sign-in probe so the composer note (with its sign-in link) appears.
    useGenerate.getState().probe();
    return "Sign in to Donkey to chat with Gemini.";
  }
  const body = (await res.json().catch(() => null)) as {
    error?: unknown;
    message?: unknown;
  } | null;
  const message = [body?.message, body?.error].find(
    (v): v is string => typeof v === "string" && v.length > 0
  );
  if (res.status === 402) {
    return message ?? "Not enough Donkey credits — top up in Settings to keep chatting.";
  }
  return message ?? "Gemini request failed.";
}

/** Server-side skills resolve locally; everything else runs on the editor store. */
async function execTool(name: string, args: Record<string, unknown>): Promise<unknown> {
  if (name === "list_skills") return { skills: AI_SKILL_INDEX };
  if (name === "read_skill") {
    const doc = AI_SKILLS[String(args.name ?? "")];
    if (!doc) throw new Error(`No such skill. Available: ${AI_SKILL_INDEX.join(", ")}`);
    return doc;
  }
  return runAiTool(name, args);
}

/** A tool result as a function_response content part. Screenshots leave the
 * JSON (a data URL inlined as text would blow the token budget) and ride along
 * as an image part instead, so the model actually sees the frame. */
function functionResponsePart(name: string, output: unknown): Item {
  if (output && typeof output === "object" && "image" in output) {
    const { image, ...rest } = output as { image?: unknown };
    const match = typeof image === "string" ? /^data:([^;,]+);base64,(.+)$/.exec(image) : null;
    if (match) {
      return {
        type: "function_response",
        name,
        response: rest,
        mimeType: match[1],
        screenshotBase64: match[2],
      };
    }
  }
  const response =
    output && typeof output === "object" && !Array.isArray(output)
      ? output
      : { result: output ?? null };
  return { type: "function_response", name, response };
}

interface ResponseBody {
  output_text?: string;
  output?: { type?: string; id?: string; name?: string; arguments?: unknown }[];
}

/** One chat turn: request → (tool round-trips) → reply, streamed as UI chunks. */
export function streamGeminiChat({
  model,
  messages,
  abortSignal,
}: {
  model: string;
  messages: UIMessage[];
  abortSignal?: AbortSignal;
}): ReadableStream<UIMessageChunk> {
  return new ReadableStream<UIMessageChunk>({
    async start(controller) {
      const emit = (chunk: Record<string, unknown>) =>
        controller.enqueue(chunk as unknown as UIMessageChunk);
      emit({ type: "start" });
      try {
        const input = inputFromMessages(messages);
        const tools = toolDeclarations();
        let textCount = 0;
        let settled = false;

        for (let round = 0; round < MAX_TOOL_ROUNDS && !settled; round++) {
          const res = await hostedPost(
            "/api/inference/responses",
            { donkeyProvider: "gemini", model, instructions: systemPrompt(), input, tools },
            abortSignal
          );
          if (!res.ok) throw new Error(await requestError(res));
          const body = (await res.json()) as ResponseBody;

          const assistantParts: Item[] = [];
          const text = (body.output_text ?? "").trim();
          if (text) {
            const id = `t${++textCount}`;
            emit({ type: "text-start", id });
            emit({ type: "text-delta", id, delta: text });
            emit({ type: "text-end", id });
            assistantParts.push({ text });
          }

          const calls = (body.output ?? []).filter((o) => o.type === "function_call");
          if (calls.length === 0) {
            settled = true;
            // Gemini can return an empty STOP round — no text, no tool calls
            // (same class as the empty-TTS behavior). Without this the stream
            // finishes having emitted nothing and the reply bubble stays blank.
            if (textCount === 0) {
              emit({ type: "error", errorText: "Gemini returned an empty response. Try again." });
            }
            break;
          }

          // Parallel calls stay in one model turn, with every response in the
          // single user turn that follows — the shape Gemini expects back.
          const responseParts: Item[] = [];
          for (const call of calls) {
            const name = String(call.name ?? "unknown_function");
            const args =
              call.arguments && typeof call.arguments === "object" && !Array.isArray(call.arguments)
                ? (call.arguments as Record<string, unknown>)
                : {};
            assistantParts.push({ functionCall: { name, args } });
            if (abortSignal?.aborted) return;
            const toolCallId = String(call.id ?? crypto.randomUUID().slice(0, 12));
            emit({ type: "tool-input-available", toolCallId, toolName: name, input: args });
            try {
              const output = await execTool(name, args);
              emit({ type: "tool-output-available", toolCallId, output: output ?? null });
              responseParts.push(functionResponsePart(name, output));
            } catch (err) {
              const errorText = err instanceof Error ? err.message : String(err);
              emit({ type: "tool-output-error", toolCallId, errorText });
              responseParts.push(functionResponsePart(name, { error: errorText }));
            }
          }
          input.push({ role: "assistant", content: assistantParts });
          input.push({ role: "user", content: responseParts });
        }

        if (!settled) {
          emit({ type: "error", errorText: "Gemini stopped after too many tool rounds." });
        }
      } catch (err) {
        if (!abortSignal?.aborted) {
          emit({ type: "error", errorText: err instanceof Error ? err.message : String(err) });
        }
      } finally {
        emit({ type: "finish" });
        controller.close();
      }
    },
  });
}

"use client";

// Donkey's hosted inference routes, called from the page with the user's
// session and credits (the one hosted carve-out on the otherwise local-only
// Cut page). Shared by media generation, prompt composition, and AI chat.

const CLIENT_ID = "donkey-cut";

/** POST one of Donkey's hosted inference routes with the user's session. */
export const hostedPost = (path: string, body: unknown, signal?: AbortSignal) =>
  fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-donkey-client-id": CLIENT_ID },
    body: JSON.stringify(body),
    signal,
  });

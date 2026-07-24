// Wake the render worker's container. Fire-and-forget: a lost wake self-heals
// because the client keeps polling its queued job, and every such poll wakes
// again. The URL is per-deployment cross-service wiring (the Worker's
// workers.dev address), so it rides env beside the secret; with neither set
// (local dev), the dev worker is run by hand and polls on its own.
const wakeUrl = () => process.env.CUT_RENDER_WAKE_URL;

export function wakeRenderWorker(): void {
  const url = wakeUrl();
  if (!url) return;
  void fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${process.env.CUT_RENDER_WAKE_SECRET ?? ""}` },
  }).catch(() => {});
}

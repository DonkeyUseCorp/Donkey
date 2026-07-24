"use client";

import Image from "next/image";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Loader2, Plug, ShieldX } from "lucide-react";

import { DONKEY_DOWNLOAD_URL } from "@/app/_components/landing/data";
import { track } from "@/lib/analytics";
import { Button } from "@/components/ui/button";
import {
  ENGINE_LOST_EVENT,
  engineConnect,
  engineGateOpen,
  engineProbe,
  servedFromEngine,
} from "@/cut/lib/api";
import { cutMode, setCutMode } from "@/cut/lib/backend";
import { enableWebMode, useWebMode, webModeEnabled } from "@/cut/lib/flags";

// Chrome gates a public https page's first fetch to 127.0.0.1 behind its
// Local Network Access prompt — "donkeycut.com wants to access other apps and
// services on this device". This gate renders the app blurred and inert
// behind a modal until an engine probe actually succeeds, and asks with its
// own UI first: while the browser permission is unresolved, the request that
// raises Chrome's prompt only ever starts from the user's Connect click, so
// the prompt can never ambush a login. The api.ts gate latch holds the
// mounted app's own requests until the gate opens, making that true by
// construction. The modal has two shapes:
//
//   connect/install — no engine has answered: ask to connect (browser prompt
//     pending) or to install/open the Donkey app, with a direct DMG download.
//   blocked — the permission is denied; site-settings recovery.
//
// Once the permission is granted (or the page is served by the engine, where
// loopback is same-origin) the gate probes quietly and keeps polling, so the
// page springs to life the moment the app starts. Engine loss anywhere in
// the app (api.ts's engineLost) puts the modal back up.

// Set after a user-initiated connect. Only consulted when the permission
// state can't be queried (non-Chrome, older Chrome): there it marks the
// browser ask as already answered, making mount-time probing safe.
const ACK_KEY = "cut-engine-connect-acked";

type Gate = "checking" | "install" | "connecting" | "blocked" | "pass";

/** Dev-only preview of a gate state, since localhost normally passes straight
 * through: ?gate=ask (connect ask) | install (get-the-app variant) |
 * connecting | blocked. Compiled out of production builds. */
function forcedGate(): string | null {
  if (process.env.NODE_ENV === "production") return null;
  return new URLSearchParams(window.location.search).get("gate");
}

/** The browser's local-network permission state, null where the permission
 * (or the query) doesn't exist — non-Chrome browsers, older Chrome. */
async function permissionState(): Promise<PermissionState | null> {
  try {
    const status = await navigator.permissions.query({
      name: "local-network-access" as PermissionName,
    });
    return status.state;
  } catch {
    return null;
  }
}

export function ConnectGate({ children }: { children: ReactNode }) {
  const [gate, setGate] = useState<Gate>("checking");
  // Whether starting a probe would raise the browser's permission prompt.
  // True blocks all automatic probing and turns the modal into the connect
  // ask.
  const [needsAsk, setNeedsAsk] = useState(false);

  const pass = useCallback(() => {
    setCutMode("local");
    engineGateOpen();
    setGate("pass");
  }, []);

  // Web mode (the cut-web-mode flag): the app runs against the cloud backend,
  // so a missing engine never walls the page — the gate still prefers the
  // engine when it can probe without raising the browser ask, and otherwise
  // passes straight through in cloud mode. The engine gate latch stays closed
  // there; nothing in cloud mode touches loopback.
  const passCloud = useCallback(() => {
    setCutMode("cloud");
    setGate("pass");
  }, []);

  const check = useCallback(async () => {
    const forced = forcedGate();
    if (forced) {
      setNeedsAsk(forced === "ask" || forced === "connecting");
      return setGate(forced === "ask" ? "install" : (forced as Gate));
    }
    const web = webModeEnabled();
    const perm = await permissionState();
    if (perm === "denied") {
      if (web) passCloud();
      else setGate("blocked");
      return;
    }
    const quiet =
      servedFromEngine() ||
      perm === "granted" ||
      (perm === null && localStorage.getItem(ACK_KEY) === "1");
    setNeedsAsk(!quiet);
    if (!quiet) {
      if (web) passCloud();
      else setGate("install");
      return;
    }
    try {
      await engineProbe();
      pass();
    } catch {
      if (web) passCloud();
      else setGate("install");
    }
  }, [pass, passCloud]);

  useEffect(() => {
    void check();
  }, [check]);

  // The flag flips on the fly from the account menu: turning it on releases a
  // gated page into cloud mode via a fresh check; turning it off while running
  // on the cloud backend puts the gate back up on the local flow.
  const webMode = useWebMode();
  useEffect(() => {
    const flip = webMode ? gate === "install" || gate === "blocked" : cutMode() === "cloud";
    if (!flip) return;
    if (!webMode) setCutMode("local");
    const t = setTimeout(() => void check(), 0);
    return () => clearTimeout(t);
  }, [webMode, gate, check]);

  // While waiting with a prompt-free path to loopback, keep probing so the
  // page connects the moment the app starts.
  useEffect(() => {
    if (gate !== "install" || needsAsk || forcedGate()) return;
    const t = setInterval(() => {
      engineProbe().then(pass, () => {});
    }, 3000);
    return () => clearInterval(t);
  }, [gate, needsAsk, pass]);

  // The engine stopped answering mid-session: put the modal back up (its
  // polling then restores the app when the engine does).
  useEffect(() => {
    const onLost = () => setGate((g) => (g === "pass" ? "install" : g));
    window.addEventListener(ENGINE_LOST_EVENT, onLost);
    return () => window.removeEventListener(ENGINE_LOST_EVENT, onLost);
  }, []);

  // "Try Donkey Cut Cloud": enables the account's cut-web-mode flag right from
  // the wall. On success the flag-flip effect above sees a walled gate with
  // the flag on and releases the page into cloud mode.
  const [cloudTrying, setCloudTrying] = useState(false);
  const [cloudError, setCloudError] = useState(false);
  const tryCloud = async () => {
    track("cut_cloud_enable_clicked", {
      source:
        gate === "blocked"
          ? "connect_gate_blocked"
          : needsAsk
            ? "connect_gate_ask"
            : "connect_gate_install",
    });
    setCloudTrying(true);
    setCloudError(false);
    const ok = await enableWebMode();
    setCloudTrying(false);
    if (!ok) setCloudError(true);
  };

  const connect = async () => {
    setGate("connecting");
    localStorage.setItem(ACK_KEY, "1");
    if (await engineConnect()) return pass();
    // No engine answered, but the browser ask may still have been decided.
    const perm = await permissionState();
    if (perm === "denied") return setGate("blocked");
    setNeedsAsk(perm === "prompt");
    setGate("install");
  };

  const gated = gate !== "pass";
  const connecting = gate === "connecting";

  const cloudCta = (
    <div className="mt-2 self-start text-left text-xs text-muted-foreground">
      <p>
        <button
          className="font-medium text-foreground underline underline-offset-2 disabled:opacity-60"
          disabled={cloudTrying}
          onClick={() => void tryCloud()}
          type="button"
        >
          {cloudTrying ? "Turning on…" : "Try Donkey Cut Cloud (Beta)"}
        </button>{" "}
        — edit right here in the browser, no install. Projects are stored in
        the cloud and exports render on cloud servers. You can always install
        the Donkey Mac app to enable local processing.
      </p>
      {cloudError && <p className="mt-1 text-red-600">Couldn&rsquo;t turn that on — try again.</p>}
    </div>
  );

  return (
    <>
      <div inert={gated || undefined}>{children}</div>
      {gated && (
        <div className="fixed inset-0 z-50 grid place-items-center overflow-y-auto bg-black/25 p-6 backdrop-blur-md">
          {gate === "checking" ? (
            <Loader2 className="size-5 animate-spin text-white/80" />
          ) : gate === "blocked" ? (
            <div className="flex w-full max-w-xl flex-col items-center gap-4 rounded-2xl border bg-background p-8 text-center shadow-2xl">
              <div className="grid size-14 place-items-center rounded-2xl bg-muted">
                <ShieldX className="size-7 text-muted-foreground" />
              </div>
              <h1 className="text-lg font-semibold tracking-tight">Connection blocked</h1>
              <p className="self-start text-left text-sm text-muted-foreground">
                Your browser is blocking this page from reaching the Donkey
                app on this Mac. Open the site settings from the icon next to
                the address bar, turn on{" "}
                <span className="font-medium text-foreground">Apps on device</span>,
                then try again.
              </p>
              <Image
                alt="Chrome's site settings open over the address bar, with the Apps on device toggle"
                className="w-full max-w-sm rounded-xl border shadow-sm"
                height={660}
                src="/cut/connect-site-settings.png"
                unoptimized
                width={970}
              />
              <Button onClick={() => void check()}>Try again</Button>
              {cloudCta}
            </div>
          ) : (
            <div className="flex w-full max-w-xl flex-col items-center gap-4 rounded-2xl border bg-background p-8 text-center shadow-2xl">
              <div className="grid size-14 place-items-center rounded-2xl bg-muted">
                <Plug className="size-7 text-muted-foreground" />
              </div>
              <h1 className="text-lg font-semibold tracking-tight">
                {needsAsk ? "Connect to the Donkey app" : "Donkey Cut works with the Donkey Mac app"}
              </h1>
              <p className="self-start text-left text-sm text-muted-foreground">
                {needsAsk ? (
                  <>
                    Donkey Cut runs locally in the Donkey app on this Mac.
                    Your browser will ask for permission to connect to apps on
                    this device — choose{" "}
                    <span className="font-medium text-foreground">Allow</span>.
                  </>
                ) : (
                  <>
                    Everything runs locally on your Mac. Install Donkey, or
                    open it if it&rsquo;s already installed — this page
                    connects automatically.
                  </>
                )}
              </p>
              {needsAsk ? (
                <Button onClick={() => void connect()} disabled={connecting}>
                  {connecting && (
                    <Loader2 className="animate-spin" data-icon="inline-start" />
                  )}
                  {connecting ? "Connecting…" : "Connect"}
                </Button>
              ) : (
                <div className="flex items-center gap-2">
                  <Button
                    onClick={() => {
                      track("app_install_clicked", { source: "connect_gate_button" });
                      window.location.href = DONKEY_DOWNLOAD_URL;
                    }}
                  >
                    Download for Mac
                  </Button>
                  <Button variant="ghost" onClick={() => void connect()} disabled={connecting}>
                    {connecting && (
                      <Loader2 className="animate-spin" data-icon="inline-start" />
                    )}
                    {connecting ? "Connecting…" : "Try again"}
                  </Button>
                </div>
              )}
              {needsAsk && (
                <p className="self-start text-left text-xs text-muted-foreground">
                  Don&rsquo;t have the Donkey app yet?{" "}
                  <a
                    className="font-medium text-foreground underline underline-offset-2"
                    href={DONKEY_DOWNLOAD_URL}
                    onClick={() => track("app_install_clicked", { source: "connect_gate_link" })}
                  >
                    Install it for Mac
                  </a>
                </p>
              )}
              {cloudCta}
            </div>
          )}
        </div>
      )}
    </>
  );
}

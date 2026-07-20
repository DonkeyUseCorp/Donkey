"use client";

import Image from "next/image";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Loader2, Plug, ShieldX } from "lucide-react";

import { Button } from "@/components/ui/button";
import { engineConnect, servedFromEngine } from "@/cut/lib/api";

// Chrome gates a public https page's first fetch to 127.0.0.1 behind its
// Local Network Access prompt — "donkeycut.com wants to access other apps and
// services on this device". Left to fire from the projects list's mount-time
// probe, it ambushes the user right after login, and a reflexive Block
// silently strands every engine call. This gate holds the Cut app subtree
// until the user starts the connection themselves: a connect screen says what
// the browser is about to ask, the Connect click runs the first probe (which
// waits out the prompt), and a denied permission gets its own recovery
// screen. The screen shows once per browser — once connected (or
// acknowledged), later visits pass straight through — and never when the page
// is served by the engine itself, where loopback is same-origin.

const ACK_KEY = "cut-engine-connect-acked";

type Gate = "checking" | "connect" | "connecting" | "blocked" | "pass";

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

  const check = useCallback(async () => {
    const perm = await permissionState();
    if (servedFromEngine() || perm === "granted") return setGate("pass");
    if (perm === "denied") return setGate("blocked");
    if (localStorage.getItem(ACK_KEY) === "1") return setGate("pass");
    setGate("connect");
  }, []);

  useEffect(() => {
    void check();
  }, [check]);

  const connect = async () => {
    setGate("connecting");
    localStorage.setItem(ACK_KEY, "1");
    await engineConnect();
    // Any answer resolves the probe; only an explicit Block needs its own
    // screen. Everything else falls through to the app, which shows its own
    // get-Donkey state when no engine answered.
    setGate((await permissionState()) === "denied" ? "blocked" : "pass");
  };

  if (gate === "pass") return <>{children}</>;

  if (gate === "checking")
    return (
      <div className="grid min-h-screen place-items-center text-muted-foreground">
        <Loader2 className="size-5 animate-spin" />
      </div>
    );

  if (gate === "blocked")
    return (
      <div className="grid min-h-screen place-items-center">
        <div className="flex max-w-sm flex-col items-center gap-4 text-center">
          <div className="grid size-14 place-items-center rounded-2xl bg-muted">
            <ShieldX className="size-7 text-muted-foreground" />
          </div>
          <h1 className="text-lg font-semibold tracking-tight">Connection blocked</h1>
          <p className="text-sm text-muted-foreground">
            Your browser is blocking this page from reaching the Donkey app on
            this Mac. Open the site settings from the icon next to the address
            bar, turn on{" "}
            <span className="font-medium text-foreground">Apps on device</span>,
            then try again.
          </p>
          <Image
            alt="Chrome's site settings open over the address bar, with the Apps on device toggle"
            className="w-full rounded-xl border shadow-sm [mask-image:linear-gradient(to_bottom,black_72%,transparent)]"
            height={660}
            src="/cut/connect-site-settings.png"
            unoptimized
            width={970}
          />
          <Button onClick={() => void check()}>Try again</Button>
        </div>
      </div>
    );

  const connecting = gate === "connecting";
  return (
    <div className="grid min-h-screen place-items-center">
      <div className="flex max-w-sm flex-col items-center gap-4 text-center">
        <div className="grid size-14 place-items-center rounded-2xl bg-muted">
          <Plug className="size-7 text-muted-foreground" />
        </div>
        <h1 className="text-lg font-semibold tracking-tight">Connect to the Donkey app</h1>
        <p className="text-sm text-muted-foreground">
          Donkey Cut runs locally — your projects live in the Donkey app on
          this Mac. Your browser will ask for permission to connect to apps on
          this device; choose <span className="font-medium text-foreground">Allow</span>.
        </p>
        <Button onClick={() => void connect()} disabled={connecting}>
          {connecting && <Loader2 className="animate-spin" data-icon="inline-start" />}
          {connecting ? "Choose Allow when your browser asks" : "Connect"}
        </Button>
      </div>
    </div>
  );
}

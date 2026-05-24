"use client";

import { ArrowRight } from "lucide-react";
import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";

import { authClient } from "@/lib/auth-client";

type Props = {
  state: string | null;
};

type RedirectStatus = "opening" | "failed" | "missing-state";

export function MacAuthRedirector({ state }: Props) {
  const [status, setStatus] = useState<RedirectStatus>("opening");
  const hasStartedRef = useRef(false);

  const startGoogleAuth = useCallback(async () => {
    if (!state) {
      setStatus("missing-state");
      return;
    }

    setStatus("opening");
    const encodedState = encodeURIComponent(state);
    const callbackURL = `/mac-auth/callback?state=${encodedState}`;

    try {
      await authClient.signIn.social({
        callbackURL,
        errorCallbackURL: `${callbackURL}&error=oauth`,
        provider: "google",
      });
    } catch {
      setStatus("failed");
    }
  }, [state]);

  useEffect(() => {
    if (hasStartedRef.current) {
      return;
    }

    hasStartedRef.current = true;
    void startGoogleAuth();
  }, [startGoogleAuth]);

  const retry = useCallback(() => {
    hasStartedRef.current = true;
    void startGoogleAuth();
  }, [startGoogleAuth]);

  return (
    <main className="box-border flex min-h-screen items-center justify-center bg-[#1f201e] px-6 py-6 text-[#f7f4ee]">
      <section className="grid w-full max-w-[460px] justify-items-center gap-[18px] text-center">
        <Image
          alt=""
          className="size-[72px] rounded-[18px] shadow-[0_18px_44px_rgba(0,0,0,0.32)]"
          height={72}
          src="/donkey-app-icon.png"
          width={72}
        />

        <h1 className="mt-[22px] text-[42px] leading-[1.05] font-extrabold tracking-normal">
          {headingForStatus(status)}
        </h1>

        <p className="m-0 max-w-[420px] text-[17px] leading-6 text-[#f7f4ee]/68">
          {messageForStatus(status)}
        </p>

        {status === "failed" ? (
          <button
            className="mt-[14px] inline-flex h-12 cursor-pointer items-center justify-center gap-2.5 rounded-xl border-0 bg-[#f7f4ee] px-[22px] text-base font-extrabold text-[#222]"
            onClick={retry}
            type="button"
          >
            Try again
            <ArrowRight aria-hidden="true" size={18} />
          </button>
        ) : null}
      </section>

    </main>
  );
}

function headingForStatus(status: RedirectStatus) {
  switch (status) {
    case "failed":
    case "missing-state":
      return "Google sign-in paused";
    case "opening":
      return "Continuing with Google";
  }
}

function messageForStatus(status: RedirectStatus) {
  switch (status) {
    case "failed":
      return "Google sign-in could not start in this browser.";
    case "missing-state":
      return "The Mac app state token was missing from this sign-in request.";
    case "opening":
      return "Use your Google account, then Donkey will bring you back to the Mac app.";
  }
}

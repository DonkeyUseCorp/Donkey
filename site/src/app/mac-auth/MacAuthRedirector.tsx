"use client";

import { ArrowRight, LoaderCircle } from "lucide-react";
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
    <main
      style={{
        alignItems: "center",
        background: "#1f201e",
        boxSizing: "border-box",
        color: "#f7f4ee",
        display: "flex",
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        justifyContent: "center",
        minHeight: "100vh",
        padding: 24,
      }}
    >
      <section
        style={{
          alignItems: "center",
          display: "grid",
          gap: 18,
          justifyItems: "center",
          maxWidth: 460,
          textAlign: "center",
          width: "100%",
        }}
      >
        <div
          style={{
            alignItems: "center",
            background: "#df704a",
            borderRadius: 18,
            display: "flex",
            height: 68,
            justifyContent: "center",
            width: 68,
          }}
        >
          <LoaderCircle
            aria-hidden="true"
            size={34}
            strokeWidth={2.5}
            style={{
              animation: status === "opening" ? "donkey-spin 1s linear infinite" : undefined,
            }}
          />
        </div>

        <h1
          style={{
            fontSize: 42,
            fontWeight: 800,
            letterSpacing: 0,
            lineHeight: 1.05,
            margin: "22px 0 0",
          }}
        >
          {status === "opening" ? "Opening Google" : "Google sign-in paused"}
        </h1>

        <p
          style={{
            color: "rgba(247, 244, 238, 0.68)",
            fontSize: 17,
            lineHeight: 1.5,
            margin: 0,
          }}
        >
          {messageForStatus(status)}
        </p>

        {status === "failed" ? (
          <button
            onClick={retry}
            style={{
              alignItems: "center",
              background: "#f7f4ee",
              border: 0,
              borderRadius: 12,
              color: "#222",
              cursor: "pointer",
              display: "inline-flex",
              fontSize: 16,
              fontWeight: 800,
              gap: 10,
              height: 48,
              justifyContent: "center",
              marginTop: 14,
              padding: "0 22px",
            }}
            type="button"
          >
            Try again
            <ArrowRight aria-hidden="true" size={18} />
          </button>
        ) : null}
      </section>

      <style jsx>{`
        @keyframes donkey-spin {
          to {
            transform: rotate(360deg);
          }
        }
      `}</style>
    </main>
  );
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

"use client";

import { ArrowRight, ShieldCheck, Sparkles } from "lucide-react";
import { useCallback, useState } from "react";

import {
  PillButton,
  SectionLabel,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { Footer } from "@/app/_components/landing/Footer";
import { TopNav } from "@/app/_components/landing/TopNav";
import { BG, BLACK, CARD } from "@/app/_components/landing/theme";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { authClient } from "@/lib/auth-client";

type AuthMode = "sign-in" | "sign-up";

type Props = {
  mode: AuthMode;
};

const copy = {
  "sign-in": {
    alternateHref: "/sign-up",
    alternateLabel: "Create account",
    eyebrow: "Welcome back",
    heading: "Sign in and send Donkey back to work.",
    supporting:
      "Use the same Google account you used for Donkey. Your billing and downloads stay tied to one clean account.",
    title: "Sign in",
  },
  "sign-up": {
    alternateHref: "/sign-in",
    alternateLabel: "Sign in",
    eyebrow: "Start your account",
    heading: "Create an account for the work Donkey carries.",
    supporting:
      "Google OAuth keeps setup quick and gives checkout a real account to attach your subscription to.",
    title: "Sign up",
  },
} satisfies Record<
  AuthMode,
  {
    alternateHref: string;
    alternateLabel: string;
    eyebrow: string;
    heading: string;
    supporting: string;
    title: string;
  }
>;

export function AuthScreen({ mode }: Props) {
  const isDesktop = useMediaQuery("(min-width: 900px)");
  const [isPending, setIsPending] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const screenCopy = copy[mode];

  const handleGoogleAuth = useCallback(async () => {
    const searchParams = new URLSearchParams(window.location.search);
    const callbackURL = searchParams.get("callbackURL") ?? "/pricing";

    setIsPending(true);
    setStatusMessage(null);

    try {
      await authClient.signIn.social({
        callbackURL,
        provider: "google",
      });
    } catch {
      setStatusMessage("Google sign-in could not start. Please try again.");
    } finally {
      setIsPending(false);
    }
  }, []);

  return (
    <main
      style={{
        WebkitFontSmoothing: "antialiased",
        background: BG,
        color: BLACK,
        boxSizing: "border-box",
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        maxWidth: "100%",
        minHeight: "100vh",
        overflowX: "hidden",
        width: "100%",
      }}
    >
      <TopNav ctaHref="/pricing" ctaLabel="Pricing" />
      <section
        style={{
          display: "grid",
          gap: isDesktop ? 48 : 32,
          gridTemplateColumns: isDesktop ? "minmax(0, 1.05fr) minmax(360px, 0.8fr)" : "1fr",
          boxSizing: "border-box",
          margin: "0 auto",
          maxWidth: 1400,
          padding: isDesktop ? "72px 48px 120px" : "44px 24px 80px",
          width: "100%",
        }}
      >
        <div>
          <SectionLabel number={1}>{screenCopy.eyebrow}</SectionLabel>
          <h1
            style={{
              fontSize: isDesktop ? 92 : 52,
              fontWeight: 900,
              letterSpacing: 0,
              lineHeight: 0.9,
              margin: 0,
              maxWidth: 920,
              overflowWrap: "break-word",
            }}
          >
            {screenCopy.heading}
          </h1>
          <p
            style={{
              color: "#454545",
              fontSize: isDesktop ? 20 : 18,
              lineHeight: 1.55,
              marginTop: 32,
              maxWidth: 620,
            }}
          >
            {screenCopy.supporting}
          </p>
        </div>

        <div style={{ alignSelf: "start" }}>
          <TapedCard color="cream" tapeColor="coral" tapePosition="center">
            <div style={{ padding: isDesktop ? 36 : 28 }}>
              <div
                style={{
                  alignItems: "center",
                  background: CARD.blue,
                  border: `2px solid ${BLACK}`,
                  borderRadius: 14,
                  display: "inline-flex",
                  height: 56,
                  justifyContent: "center",
                  marginBottom: 28,
                  width: 56,
                }}
              >
                <Sparkles size={24} />
              </div>
              <h2
                style={{
                  fontSize: isDesktop ? 42 : 34,
                  fontWeight: 900,
                  lineHeight: 1,
                  margin: "0 0 14px",
                }}
              >
                {screenCopy.title}
              </h2>
              <p
                style={{
                  color: "#444",
                  fontSize: 15,
                  lineHeight: 1.55,
                  margin: "0 0 28px",
                }}
              >
                Donkey uses Google sign-in so checkout, subscriptions, and account
                access stay simple.
              </p>
              <div style={{ display: "grid", gap: 12 }}>
                <PillButton
                  disabled={isPending}
                  onClick={handleGoogleAuth}
                  size="lg"
                  variant="dark"
                >
                  {isPending ? "Opening Google..." : "Continue with Google"}
                  <ArrowRight size={18} />
                </PillButton>
                <PillButton
                  href={screenCopy.alternateHref}
                  size="lg"
                  variant="secondary"
                >
                  {screenCopy.alternateLabel}
                </PillButton>
              </div>
              <p
                style={{
                  color: "#555",
                  fontSize: 12,
                  lineHeight: 1.5,
                  margin: "18px 0 0",
                }}
              >
                By continuing, you agree to the{" "}
                <a
                  href="/terms/"
                  style={{ color: BLACK, fontWeight: 800 }}
                >
                  Terms of Use
                </a>{" "}
                and{" "}
                <a
                  href="/privacy/"
                  style={{ color: BLACK, fontWeight: 800 }}
                >
                  Privacy Policy
                </a>
                .
              </p>
              {statusMessage ? (
                <div
                  role="status"
                  style={{
                    color: "#4a403d",
                    fontSize: 13,
                    fontWeight: 700,
                    lineHeight: 1.4,
                    marginTop: 14,
                  }}
                >
                  {statusMessage}
                </div>
              ) : null}
            </div>
          </TapedCard>

          <div
            style={{
              alignItems: "center",
              display: "flex",
              gap: 12,
              marginTop: 24,
            }}
          >
            <div
              style={{
                alignItems: "center",
                background: CARD.mint,
                border: `2px solid ${BLACK}`,
                borderRadius: 12,
                display: "flex",
                height: 44,
                justifyContent: "center",
                width: 44,
              }}
            >
              <ShieldCheck size={20} />
            </div>
            <div style={{ color: "#555", fontSize: 14, lineHeight: 1.4 }}>
              OAuth only. No passwords to store, reset, or lose.
            </div>
          </div>
        </div>
      </section>
      <Footer />
    </main>
  );
}

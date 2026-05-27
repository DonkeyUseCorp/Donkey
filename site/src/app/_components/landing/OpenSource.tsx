"use client";

import { ArrowRight } from "lucide-react";

import {
  Headline,
  PillButton,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { GITHUB_REPO_URL, openSourceReasons } from "@/app/_components/landing/data";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK } from "@/app/_components/landing/theme";

export function OpenSource() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      style={{
        padding: isDesktop ? "96px 48px" : "80px 24px",
        maxWidth: 1400,
        margin: "0 auto",
      }}
    >
      <Headline>
        Donkey is yours. <span style={{ fontStyle: "italic" }}>All of it.</span>
      </Headline>
      <p
        style={{
          marginTop: 24,
          fontSize: 17,
          lineHeight: 1.55,
          maxWidth: 600,
          color: "#454545",
        }}
      >
        Donkey is built in the open. Read the source, run your own build,
        contribute an agent: it is all on GitHub.
      </p>

      <div style={{ marginTop: 32 }}>
        <TapedCard color="cream" shadowColor="coral" tapeColor="coral">
          <div style={{ padding: isDesktop ? 40 : 24 }}>
            <div
              style={{
                background: BLACK,
                borderRadius: 12,
                padding: isDesktop ? "24px" : "20px 18px",
                fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
                fontSize: isDesktop ? 15 : 13,
                color: "#fff",
                overflowX: "auto",
              }}
            >
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  marginBottom: 16,
                  color: "#888",
                }}
              >
                <span
                  style={{
                    width: 10,
                    height: 10,
                    borderRadius: 999,
                    background: "#FF5F57",
                  }}
                />
                <span
                  style={{
                    width: 10,
                    height: 10,
                    borderRadius: 999,
                    background: "#FEBC2E",
                  }}
                />
                <span
                  style={{
                    width: 10,
                    height: 10,
                    borderRadius: 999,
                    background: "#28C840",
                  }}
                />
                <span style={{ marginLeft: 8, fontSize: 12 }}>
                  ~/ - DonkeyUseCorp/Donkey
                </span>
              </div>
              <div style={{ color: "#b7b7b7", whiteSpace: "nowrap" }}>
                <span style={{ color: "#5FFFB9" }}>$</span> git clone{" "}
                {GITHUB_REPO_URL}
              </div>
              <div style={{ color: "#b7b7b7", marginTop: 4, whiteSpace: "nowrap" }}>
                <span style={{ color: "#5FFFB9" }}>$</span> cd donkey && make
                run
              </div>
              <div style={{ color: "#5FFFB9", marginTop: 12 }}>
                Donkey running locally - http://localhost:5005
              </div>
            </div>

            <div
              style={{
                marginTop: 24,
                display: "flex",
                flexWrap: "wrap",
                gap: 12,
                alignItems: "center",
              }}
            >
              <PillButton href={GITHUB_REPO_URL} variant="dark" size="md">
                Star on GitHub <ArrowRight size={14} />
              </PillButton>
              <PillButton href="/prototype" variant="secondary" size="md">
                View prototype
              </PillButton>
            </div>
          </div>
        </TapedCard>
      </div>

      <div
        style={{
          marginTop: 24,
          display: "grid",
          gridTemplateColumns: isDesktop ? "1fr 1fr" : "1fr",
          gap: 16,
        }}
      >
        {openSourceReasons.map((reason) => (
          <TapedCard key={reason.title} color={reason.color} tapeColor="cream">
            <div
              style={{
                padding: 24,
                display: "flex",
                alignItems: "flex-start",
                gap: 16,
              }}
            >
              <div
                style={{
                  width: 56,
                  minWidth: 56,
                  height: 48,
                  borderRadius: 12,
                  border: `2px solid ${BLACK}`,
                  background: "#fff",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  fontSize: 12,
                  fontWeight: 600,
                }}
              >
                {reason.icon}
              </div>
              <div style={{ flex: 1 }}>
                <h3
                  style={{
                    fontWeight: 600,
                    fontSize: 22,
                    lineHeight: 1.15,
                    margin: "0 0 8px",
                  }}
                >
                  {reason.title}
                </h3>
                <p
                  style={{
                    fontSize: 14,
                    lineHeight: 1.55,
                    color: "#222",
                    margin: 0,
                  }}
                >
                  {reason.body}
                </p>
              </div>
            </div>
          </TapedCard>
        ))}
      </div>
    </section>
  );
}

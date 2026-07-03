"use client";

import { Headline } from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK, CORAL } from "@/app/_components/landing/theme";

export function Demo() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      style={{
        padding: isDesktop ? "96px 48px" : "80px 24px",
        maxWidth: 1400,
        margin: "0 auto",
      }}
    >
      <Headline size="lg">
        See Donkey <span style={{ fontStyle: "italic" }}>in action.</span>
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
        Watch Donkey take real tasks end-to-end.
      </p>

      <div style={{ marginTop: 48, position: "relative" }}>
        <div
          style={{
            position: "absolute",
            inset: 0,
            transform: "translate(6px, 6px)",
            borderRadius: 16,
            background: CORAL,
          }}
        />
        <div
          style={{
            position: "relative",
            aspectRatio: "16 / 9",
            borderRadius: 16,
            overflow: "hidden",
            border: `2px solid ${BLACK}`,
            background: BLACK,
          }}
        >
          <iframe
            src="https://www.youtube-nocookie.com/embed/g4x-HhZ8XII?cc_load_policy=0"
            title="See Donkey in action"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            allowFullScreen
            style={{
              position: "absolute",
              inset: 0,
              width: "100%",
              height: "100%",
              border: 0,
            }}
          />
        </div>
      </div>
    </section>
  );
}

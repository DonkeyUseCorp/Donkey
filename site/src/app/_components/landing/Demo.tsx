"use client";

import { Headline, TapedCard } from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK } from "@/app/_components/landing/theme";

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
      <Headline>
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
        Watch Donkey take a real task end-to-end on a Mac: reading the screen,
        driving your apps, and pausing for your sign-off.
      </p>

      <div style={{ marginTop: 48 }}>
        <TapedCard
          color="white"
          shadowColor="coral"
          tapeColor="yellow"
          tapePosition="center"
        >
          <div style={{ padding: isDesktop ? 20 : 12 }}>
            <div
              style={{
                position: "relative",
                aspectRatio: "16 / 9",
                borderRadius: 12,
                overflow: "hidden",
                border: `2px solid ${BLACK}`,
                background: BLACK,
              }}
            >
              <iframe
                src="https://www.youtube-nocookie.com/embed/g4x-HhZ8XII"
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
        </TapedCard>
      </div>
    </section>
  );
}

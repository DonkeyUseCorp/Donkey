"use client";

import { DonkeySkills } from "@/app/_components/landing/donkey-skills/DonkeySkills";
import { Headline } from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";

export function Solutions() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      style={{
        padding: isDesktop ? "96px 48px" : "80px 24px",
        maxWidth: 1400,
        margin: "0 auto",
      }}
    >
      <Headline>Donkey can do work</Headline>
      <p
        style={{
          marginTop: 24,
          fontSize: 17,
          lineHeight: 1.55,
          maxWidth: 600,
          color: "#454545",
        }}
      >
        Spreadsheets, decks, forms, clips. Donkey builds the whole thing on your
        Mac.
      </p>
      <DonkeySkills />
    </section>
  );
}

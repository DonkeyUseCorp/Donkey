"use client";

import { TopNav } from "@/app/_components/landing/TopNav";
import {
  signInHrefFor,
  signUpHrefFor,
} from "@/app/_components/landing/useAppEntryHref";

// The donkeycut.com site nav: Donkey Cut wordmark with session-aware auth
// entries. Shared by the Cut landing and the pass-through pages (e.g.
// /install) served on that host. `root` is "" on donkeycut.com and local dev,
// "/cut" on the hosted apex.
export function CutTopNav({ root }: { root: string }) {
  return (
    <TopNav
      homeHref={root || "/"}
      wordmark="Donkey Cut"
      signedInPill={{ href: `${root}/app`, label: "Go to App" }}
      signedOutAuth={{
        logInHref: signInHrefFor(`${root}/app`),
        signUpHref: signUpHrefFor(`${root}/app`),
      }}
    />
  );
}

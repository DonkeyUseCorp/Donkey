import type { Metadata } from "next";

import { MacAuthRedirector } from "@/app/mac-auth/MacAuthRedirector";

export const metadata: Metadata = {
  title: "Sign in to Donkey for Mac",
  description: "Continue Google sign-in for Donkey for Mac.",
};

type SearchParams = Record<string, string | string[] | undefined>;

type Props = {
  searchParams: Promise<SearchParams>;
};

export default async function Page({ searchParams }: Props) {
  const params = await searchParams;

  return (
    <MacAuthRedirector
      state={firstParam(params.state)}
    />
  );
}

function firstParam(value: string | string[] | undefined) {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }

  return value ?? null;
}

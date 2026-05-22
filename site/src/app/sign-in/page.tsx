import type { Metadata } from "next";

import { AuthScreen } from "@/app/_components/landing/AuthScreen";

export const metadata: Metadata = {
  title: "Sign in | Donkey",
  description: "Sign in to Donkey with Google.",
};

export default function Page() {
  return <AuthScreen mode="sign-in" />;
}

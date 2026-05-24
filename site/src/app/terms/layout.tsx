import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  alternates: {
    canonical: "https://donkeyuse.com/terms/",
  },
  description: "Read the Donkey terms of use.",
  title: "Terms of Use | Donkey",
};

type Props = {
  children: ReactNode;
};

export default function TermsLayout({ children }: Props) {
  return children;
}

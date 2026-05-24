import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  alternates: {
    canonical: "https://donkeyuse.com/privacy/",
  },
  description: "Read the Donkey privacy policy.",
  title: "Privacy Policy | Donkey",
};

type Props = {
  children: ReactNode;
};

export default function PrivacyLayout({ children }: Props) {
  return children;
}

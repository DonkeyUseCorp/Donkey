import Link from "next/link";
import { ArrowRight, Mail } from "lucide-react";

import { ContactSalesButton } from "@/app/_components/landing/ContactSalesButton";

const planFeatures = [
  "5,000 API calls per month",
  "3 requests per second",
  "Sign in with Google, generate API keys",
  "Element boxes, center points, and labels",
];

export function PricingSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 py-20 md:px-12" id="contact">
      <div className="relative">
        <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-lg bg-[#EC7868]" />
        <div className="relative grid gap-8 rounded-lg border-2 border-[#0F0E0D] bg-[#0F0E0D] p-8 text-white md:grid-cols-[1fr_auto] md:p-12">
          <div>
            <h2 className="max-w-3xl text-4xl font-semibold leading-none md:text-6xl">
              Get Donkey Vision API access.
            </h2>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-white/75">
              Self-serve from <span className="font-semibold text-white">$50/month</span>.
              Subscribe, create an API key, and start parsing screenshots in
              minutes. Need higher volume or custom limits? Talk to us.
            </p>
            <ul className="mt-8 grid max-w-2xl gap-2 text-base text-white/85 sm:grid-cols-2">
              {planFeatures.map((feature) => (
                <li key={feature} className="flex items-center gap-2">
                  <span aria-hidden="true" className="text-[#EC7868]">
                    ●
                  </span>
                  {feature}
                </li>
              ))}
            </ul>
          </div>
          <div className="flex flex-col items-stretch justify-center gap-3 md:items-end">
            <Link
              href="/dashboard"
              className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full bg-[#EC7868] px-7 text-base font-semibold text-[#0F0E0D] transition hover:-translate-y-0.5"
            >
              Get started <ArrowRight size={18} aria-hidden="true" />
            </Link>
            <ContactSalesButton className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full border border-white/30 px-7 text-base font-semibold text-white transition hover:-translate-y-0.5">
              Contact sales <Mail size={18} aria-hidden="true" />
            </ContactSalesButton>
          </div>
        </div>
      </div>
    </section>
  );
}

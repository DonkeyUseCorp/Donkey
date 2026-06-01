import { Mail } from "lucide-react";

import { ContactSalesButton } from "@/app/_components/landing/ContactSalesButton";

export function PricingSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 py-20 md:px-12" id="contact">
      <div className="relative">
        <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-lg bg-[#EC7868]" />
        <div className="relative grid gap-8 rounded-lg border-2 border-[#0F0E0D] bg-[#0F0E0D] p-8 text-white md:grid-cols-[1fr_auto] md:p-12">
          <div>
            <h2 className="max-w-3xl text-4xl font-semibold leading-none md:text-6xl">
              Contact us for Donkey Vision API access.
            </h2>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-white/75">
              Tell us your screenshot volume and latency target. We will shape
              access, request limits, and support around the experience you need.
            </p>
          </div>
          <div className="flex items-center md:justify-end">
            <ContactSalesButton
              className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full border-2 border-white bg-[#EC7868] px-7 text-base font-semibold text-[#0F0E0D] transition hover:-translate-y-0.5"
            >
              Contact us <Mail size={18} aria-hidden="true" />
            </ContactSalesButton>
          </div>
        </div>
      </div>
    </section>
  );
}

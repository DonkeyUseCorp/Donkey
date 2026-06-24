import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowRight } from "lucide-react";

import { Footer } from "@/app/_components/landing/Footer";
import {
  Headline,
  PillButton,
  SectionLabel,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { TopNav } from "@/app/_components/landing/TopNav";
import {
  getUseCasesByCategory,
  useCaseCategories,
  useCases,
} from "@/app/use-cases/useCases";

export const dynamic = "force-static";

export const metadata: Metadata = {
  title: "Mac Automation Use Cases | Donkey",
  description:
    "A library of practical Donkey use cases for PDFs, receipts, spreadsheets, media, images, web research, and Mac app automation.",
  keywords: [
    "Mac automation use cases",
    "AI desktop agent examples",
    "PDF automation",
    "receipt OCR automation",
    "CSV reporting automation",
    "Donkey use cases",
  ],
  alternates: {
    canonical: "https://donkeyuse.com/use-cases",
  },
  openGraph: {
    type: "website",
    url: "https://donkeyuse.com/use-cases",
    siteName: "Donkey",
    title: "Mac Automation Use Cases | Donkey",
    description:
      "Explore practical Donkey use cases for documents, data, media, web research, and Mac app automation.",
  },
  twitter: {
    card: "summary_large_image",
    title: "Mac Automation Use Cases | Donkey",
    description:
      "Explore practical Donkey use cases for documents, data, media, web research, and Mac app automation.",
  },
};

const structuredData = {
  "@context": "https://schema.org",
  "@type": "CollectionPage",
  name: "Donkey use cases",
  url: "https://donkeyuse.com/use-cases",
  description:
    "A library of practical Donkey use cases for PDFs, receipts, spreadsheets, media, images, web research, and Mac app automation.",
  hasPart: useCases.map((useCase, index) => ({
    "@type": "Article",
    position: index + 1,
    headline: useCase.title,
    url: `https://donkeyuse.com/use-cases/${useCase.slug}`,
  })),
};

const cardColors = [
  "blue",
  "yellow",
  "pink",
  "mint",
  "purple",
  "coral",
] as const;

export default function UseCasesPage() {
  return (
    <main className="min-h-screen w-full overflow-x-clip bg-background font-system text-ink antialiased">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
      />
      <TopNav />

      <section className="mx-auto grid w-full max-w-[1400px] grid-cols-1 gap-10 px-6 pt-12 pb-16 md:grid-cols-[minmax(0,1fr)_420px] md:px-12 md:pt-20 md:pb-24">
        <div>
          <h1 className="max-w-[860px] text-[52px] leading-[0.9] font-semibold tracking-normal break-words md:text-[108px]">
            Use cases for real Mac work.
          </h1>
          <p className="mt-8 max-w-[650px] text-[18px] leading-[1.55] text-[#454545] md:text-[20px]">
            A growing library of tasks Donkey can run across your files, apps,
            and browser. Each page starts from a harness eval, then gives the
            workflow a permanent home for examples, demos, and artifacts.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <PillButton href="/install" variant="dark">
              Try Donkey
              <ArrowRight size={16} />
            </PillButton>
            <PillButton href="/pricing" variant="secondary">
              View pricing
            </PillButton>
          </div>
        </div>

        <TapedCard color="coral" tapeColor="cream">
          <div className="p-7 md:p-8">
            <div className="mb-5 flex items-center gap-4">
              <div className="flex h-[74px] w-[74px] shrink-0 items-center justify-center overflow-hidden rounded-[14px] border-2 border-ink bg-white">
                <Image
                  alt=""
                  className="h-full w-full object-cover"
                  height={74}
                  priority
                  sizes="74px"
                  src="/donkey-site-mark.webp"
                  width={74}
                />
              </div>
              <div>
                <div className="text-[13px] font-semibold tracking-[0.12em] uppercase">
                  Library
                </div>
                <div className="mt-1 text-[34px] leading-none font-semibold">
                  {useCases.length} tasks
                </div>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              {useCaseCategories.map((category) => (
                <div
                  key={category}
                  className="rounded-lg border-2 border-ink bg-white px-4 py-3"
                >
                  <div className="text-[28px] leading-none font-semibold">
                    {getUseCasesByCategory(category).length}
                  </div>
                  <div className="mt-1 text-[13px] leading-[1.25] font-semibold text-[#454545]">
                    {category}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </TapedCard>
      </section>

      <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12 md:pb-28">
        <SectionLabel number={1}>Use case library</SectionLabel>
        <div className="flex flex-col gap-14">
          {useCaseCategories.map((category, categoryIndex) => {
            const categoryUseCases = getUseCasesByCategory(category);

            return (
              <div key={category}>
                <div className="mb-6 flex flex-col justify-between gap-3 md:flex-row md:items-end">
                  <Headline size="lg">{category}</Headline>
                  <p className="max-w-[420px] text-[15px] leading-[1.55] text-[#454545]">
                    {categoryUseCases.length} static examples pulled from the
                    current harness eval coverage.
                  </p>
                </div>
                <div className="grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-3">
                  {categoryUseCases.map((useCase, index) => {
                    const Icon = useCase.icon;
                    const color =
                      cardColors[(categoryIndex * 2 + index) % cardColors.length];

                    return (
                      <Link
                        className="block h-full text-ink no-underline"
                        href={`/use-cases/${useCase.slug}`}
                        key={useCase.slug}
                      >
                        <TapedCard
                          color={color}
                          fill
                          tapeColor="cream"
                        >
                          <article className="flex h-full min-h-[334px] flex-col p-7">
                            <div className="mb-6 flex items-center justify-between gap-4">
                              <div className="flex h-12 w-12 items-center justify-center rounded-lg border-2 border-ink bg-white">
                                <Icon size={22} />
                              </div>
                              <span className="rounded-md border-2 border-ink bg-white px-3 py-1 text-[11px] font-semibold tracking-[0.08em] uppercase">
                                Eval-backed
                              </span>
                            </div>
                            <h2 className="text-[28px] leading-[1.03] font-semibold">
                              {useCase.title}
                            </h2>
                            <p className="mt-4 text-[15px] leading-[1.55] text-[#222]">
                              {useCase.description}
                            </p>
                            <div className="mt-auto flex items-center justify-between gap-4 pt-8 text-[14px] font-semibold">
                              <span>Open use case</span>
                              <ArrowRight size={17} />
                            </div>
                          </article>
                        </TapedCard>
                      </Link>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12 md:pb-28">
        <div className="relative">
          <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-3xl bg-coral" />
          <div className="relative grid gap-8 rounded-3xl border-2 border-ink bg-ink px-7 py-9 text-white md:grid-cols-[1fr_auto] md:px-12 md:py-14">
            <div>
              <div className="mb-[18px] text-xs font-semibold tracking-[0.12em] text-white/55 uppercase">
                More examples coming
              </div>
              <Headline size="lg">Every useful eval deserves a page.</Headline>
              <p className="mt-[18px] max-w-[620px] text-[15px] leading-[1.55] text-white/72 md:text-[17px]">
                This library is built to grow as Donkey learns more repeatable
                work: demos, downloadable outputs, and search-friendly detail
                pages can be added without changing the page system.
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-3 self-center">
              <PillButton href="/install" variant="primary">
                Install Donkey
              </PillButton>
            </div>
          </div>
        </div>
      </section>

      <Footer />
    </main>
  );
}

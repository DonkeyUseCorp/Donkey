import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, ArrowRight, Download, Play } from "lucide-react";

import { Footer } from "@/app/_components/landing/Footer";
import {
  Headline,
  PillButton,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { TopNav } from "@/app/_components/landing/TopNav";
import { getUseCase, useCases } from "@/app/use-cases/useCases";

export const dynamic = "force-static";

type Params = {
  slug: string;
};

type PageProps = {
  params: Promise<Params>;
};

export function generateStaticParams() {
  return useCases.map((useCase) => ({ slug: useCase.slug }));
}

export async function generateMetadata({
  params,
}: PageProps): Promise<Metadata> {
  const { slug } = await params;
  const useCase = getUseCase(slug);

  if (!useCase) {
    return {
      title: "Use Case Not Found | Donkey",
    };
  }

  return {
    title: `${useCase.title} | Donkey Use Cases`,
    description: useCase.description,
    keywords: useCase.keywords,
    alternates: {
      canonical: `https://donkeyuse.com/use-cases/${useCase.slug}`,
    },
    openGraph: {
      type: "article",
      url: `https://donkeyuse.com/use-cases/${useCase.slug}`,
      siteName: "Donkey",
      title: `${useCase.title} | Donkey Use Cases`,
      description: useCase.description,
    },
    twitter: {
      card: "summary_large_image",
      title: `${useCase.title} | Donkey Use Cases`,
      description: useCase.description,
    },
  };
}

export default async function UseCasePage({ params }: PageProps) {
  const { slug } = await params;
  const useCase = getUseCase(slug);

  if (!useCase) {
    notFound();
  }

  const Icon = useCase.icon;
  const structuredData = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: useCase.title,
    url: `https://donkeyuse.com/use-cases/${useCase.slug}`,
    description: useCase.description,
    about: useCase.keywords,
    isPartOf: {
      "@type": "CollectionPage",
      name: "Donkey use cases",
      url: "https://donkeyuse.com/use-cases",
    },
  };

  return (
    <main className="min-h-screen w-full overflow-x-clip bg-background font-system text-ink antialiased">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
      />
      <TopNav />

      <section className="mx-auto w-full max-w-[1400px] px-6 pt-8 pb-14 md:px-12 md:pt-12 md:pb-20">
        <Link
          className="mb-8 inline-flex items-center gap-2 text-[14px] font-semibold text-ink no-underline"
          href="/use-cases"
        >
          <ArrowLeft size={16} />
          Use cases
        </Link>
        <div className="grid grid-cols-1 gap-10 md:grid-cols-[minmax(0,1fr)_420px] md:items-start">
          <div>
            <div className="mb-5 inline-flex items-center gap-2 rounded-md border-2 border-ink bg-white px-3 py-2 text-[12px] font-semibold tracking-[0.08em] uppercase">
              <Icon size={16} />
              {useCase.category}
            </div>
            <h1 className="max-w-[960px] text-[48px] leading-[0.92] font-semibold tracking-normal break-words md:text-[92px]">
              {useCase.title}
            </h1>
            <p className="mt-8 max-w-[720px] text-[18px] leading-[1.55] text-[#454545] md:text-[20px]">
              {useCase.description}
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <PillButton href="/install" variant="dark">
                Try this with Donkey
                <ArrowRight size={16} />
              </PillButton>
              <PillButton href="/pricing" variant="secondary">
                View pricing
              </PillButton>
            </div>
          </div>

          <TapedCard color="yellow" tapeColor="cream">
            <aside className="p-7">
              <div className="mb-5 flex h-[74px] w-[74px] items-center justify-center overflow-hidden rounded-[14px] border-2 border-ink bg-white">
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
              <div className="text-[12px] font-semibold tracking-[0.12em] uppercase">
                Outcome
              </div>
              <p className="mt-2 text-[16px] leading-[1.5] text-[#222]">
                {useCase.outcome}
              </p>
            </aside>
          </TapedCard>
        </div>
      </section>

      <section className="mx-auto grid w-full max-w-[1400px] grid-cols-1 gap-8 px-6 pb-20 md:grid-cols-[minmax(0,1fr)_420px] md:px-12 md:pb-28">
        <div className="min-w-0">
          <TapedCard color="blue" tapeColor="cream">
            <div className="p-7 md:p-9">
              <div className="mb-7 rounded-xl border-2 border-ink bg-white p-5">
                <div className="text-[12px] font-semibold tracking-[0.12em] uppercase text-[#666]">
                  Prompt
                </div>
                <p className="mt-2 font-code text-[15px] leading-[1.55] text-ink">
                  {useCase.prompt}
                </p>
              </div>
              <ol className="grid gap-4">
                {useCase.steps.map((step, index) => (
                  <li
                    className="grid grid-cols-[44px_minmax(0,1fr)] items-start gap-4"
                    key={step}
                  >
                    <div className="flex h-11 w-11 items-center justify-center rounded-lg border-2 border-ink bg-white text-[18px] font-semibold">
                      {String(index + 1).padStart(2, "0")}
                    </div>
                    <p className="pt-2 text-[17px] leading-[1.5] text-[#222]">
                      {step}
                    </p>
                  </li>
                ))}
              </ol>
            </div>
          </TapedCard>
        </div>

        <div className="min-w-0">
          <div className="flex flex-col gap-6">
            <TapedCard color="pink" tapeColor="cream">
              <div className="p-5">
                <div className="relative aspect-video overflow-hidden rounded-xl border-2 border-ink bg-ink">
                  {useCase.videoSrc ? (
                    <video
                      className="h-full w-full object-cover"
                      controls
                      poster="/donkey-site-mark.webp"
                      preload="metadata"
                      src={useCase.videoSrc}
                    />
                  ) : (
                    <div className="flex h-full w-full flex-col items-center justify-center gap-4 p-8 text-center text-white">
                      <div className="flex h-16 w-16 items-center justify-center rounded-full border-2 border-white bg-coral text-ink">
                        <Play size={28} fill="currentColor" />
                      </div>
                      <div>
                        <div className="text-[20px] font-semibold">
                          Demo coming soon
                        </div>
                        <p className="mt-2 text-[14px] leading-[1.45] text-white/70">
                          This static page is ready for a public demo recording
                          when one is available.
                        </p>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            </TapedCard>

            <TapedCard color="mint" tapeColor="cream">
              <div className="p-7">
                <Headline size="lg">Artifacts</Headline>
                {useCase.artifacts?.length ? (
                  <div className="mt-5 flex flex-col gap-3">
                    {useCase.artifacts.map((artifact) => (
                      <a
                        className="flex items-center justify-between gap-4 rounded-lg border-2 border-ink bg-white px-4 py-3 text-ink no-underline"
                        href={artifact.href}
                        key={artifact.href}
                      >
                        <span>
                          <span className="block text-[15px] font-semibold">
                            {artifact.label}
                          </span>
                          <span className="mt-1 block text-[13px] leading-[1.35] text-[#666]">
                            {artifact.description}
                          </span>
                        </span>
                        <Download className="shrink-0" size={18} />
                      </a>
                    ))}
                  </div>
                ) : (
                  <p className="mt-5 text-[15px] leading-[1.55] text-[#454545]">
                    This use case does not publish a downloadable fixture yet.
                    Future recordings and output files can be hosted from the
                    public use-cases folder.
                  </p>
                )}
              </div>
            </TapedCard>
          </div>
        </div>
      </section>

      <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12 md:pb-28">
        <div className="relative">
          <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-3xl bg-coral" />
          <div className="relative grid gap-8 rounded-3xl border-2 border-ink bg-ink px-7 py-9 text-white md:grid-cols-[1fr_auto] md:px-12 md:py-14">
            <div>
              <div className="mb-[18px] text-xs font-semibold tracking-[0.12em] text-white/55 uppercase">
                Try another task
              </div>
              <Headline size="lg">Browse the full library.</Headline>
              <p className="mt-[18px] max-w-[620px] text-[15px] leading-[1.55] text-white/72 md:text-[17px]">
                Donkey use cases cover file work, media, web research, desktop
                apps, and data tasks that usually take too many manual steps.
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-3 self-center">
              <PillButton href="/use-cases" variant="primary">
                All use cases
              </PillButton>
            </div>
          </div>
        </div>
      </section>

      <Footer />
    </main>
  );
}

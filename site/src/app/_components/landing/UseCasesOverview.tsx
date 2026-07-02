import Link from "next/link";
import { ArrowRight } from "lucide-react";

import {
  Headline,
  PillButton,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import type { CardColor } from "@/app/_components/landing/theme";
import {
  getUseCasesByCategory,
  useCaseCategories,
} from "@/app/use-cases/useCases";

const cardColors: CardColor[] = [
  "blue",
  "yellow",
  "pink",
  "mint",
  "purple",
  "coral",
];

// Homepage section that surfaces the full use-case library so the landing sells
// everything Donkey does, not only media. Cards mirror the /use-cases page and
// link into the detail pages.
export function UseCasesOverview() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 py-16 md:px-12 md:py-24">
      <div className="flex flex-col gap-6 md:flex-row md:items-end md:justify-between">
        <div className="max-w-[720px]">
          <Headline size="lg">Everything Donkey does</Headline>
          <p className="mt-5 text-[17px] leading-[1.55] text-[#454545] md:text-[19px]">
            Media generation is one of many. Donkey runs real work across your
            files, apps, and browser — documents, data, and desktop automation.
          </p>
        </div>
        <PillButton href="/use-cases" variant="secondary">
          See all use cases
          <ArrowRight size={16} />
        </PillButton>
      </div>

      <div className="mt-12 flex flex-col gap-14">
        {useCaseCategories.map((category, categoryIndex) => {
          const categoryUseCases = getUseCasesByCategory(category);

          return (
            <div key={category}>
              <div className="mb-6">
                <h3 className="text-[22px] leading-[1.1] font-semibold md:text-[26px]">
                  {category}
                </h3>
              </div>
              <div className="grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-3">
                {categoryUseCases.map((useCase, index) => {
                  const Icon = useCase.icon;
                  const color =
                    cardColors[
                      (categoryIndex * 2 + index) % cardColors.length
                    ];

                  return (
                    <Link
                      className="block h-full text-ink no-underline"
                      href={`/use-cases/${useCase.slug}`}
                      key={useCase.slug}
                    >
                      <TapedCard color={color} fill tapeColor="cream">
                        <article className="flex h-full min-h-[240px] flex-col p-7">
                          <div className="mb-5 flex items-center">
                            <div className="flex h-12 w-12 items-center justify-center rounded-lg border-2 border-ink bg-white">
                              <Icon size={22} />
                            </div>
                          </div>
                          <h4 className="text-[22px] leading-[1.05] font-semibold">
                            {useCase.title}
                          </h4>
                          <p className="mt-3 text-[15px] leading-[1.5] text-[#222]">
                            {useCase.description}
                          </p>
                          <div className="mt-auto flex items-center justify-end gap-2 pt-6 text-[14px] font-semibold">
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
  );
}

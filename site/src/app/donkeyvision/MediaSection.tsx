import { ImageIcon, Video, type LucideIcon } from "lucide-react";

type Props = {
  icon: LucideIcon;
  label: string;
};

export function MediaSection() {
  return (
    <section className="border-y-2 border-[#0F0E0D] bg-white px-6 py-20 md:px-12">
      <div className="mx-auto grid max-w-[1400px] gap-8 lg:grid-cols-[0.85fr_1.15fr]">
        <div>
          <h2 className="max-w-2xl text-4xl font-semibold leading-none md:text-6xl">
            Ready for real apps, not only clean demos.
          </h2>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
            This page is set up for a video walkthrough plus screenshots from
            developer tools, browsers, productivity apps, media apps, enterprise
            software, and common user applications.
          </p>
        </div>
        <div className="grid gap-5 md:grid-cols-2">
          <MediaSlot icon={Video} label="Video walkthrough" />
          <MediaSlot icon={ImageIcon} label="Application screenshots" />
        </div>
      </div>
    </section>
  );
}

function MediaSlot({ icon: Icon, label }: Props) {
  return (
    <div className="flex min-h-[260px] flex-col justify-between rounded-lg border-2 border-dashed border-[#0F0E0D] bg-[#FAF6EC] p-5">
      <div className="flex h-12 w-12 items-center justify-center rounded-md border-2 border-[#0F0E0D] bg-[#B7E4C7]">
        <Icon size={22} aria-hidden="true" />
      </div>
      <div>
        <div className="text-xl font-semibold">{label}</div>
        <div className="mt-2 text-sm leading-6 text-[#555]">
          Reserved for uploaded customer-facing media.
        </div>
      </div>
    </div>
  );
}

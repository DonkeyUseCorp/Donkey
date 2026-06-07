import { surfaces } from "@/app/donkeyvision/data";

export function MediaSection() {
  return (
    <section className="border-y-2 border-[#0F0E0D] bg-white py-20">
      <div className="mx-auto max-w-[1400px] px-6 md:px-12">
        <h2 className="text-4xl font-semibold leading-none md:whitespace-nowrap md:text-6xl">
          Works anywhere a screenshot can be captured.
        </h2>
        <p className="mt-6 text-lg leading-8 text-[#454545] md:whitespace-nowrap">
          Donkey Vision analyzes pixels directly. No DOM access, private
          integration, app-specific setup, or brittle selectors required.
        </p>
        <p className="mt-4 text-lg leading-8 text-[#454545] md:whitespace-nowrap">
          The same API request can process native apps, browser tabs, Electron
          apps, remote desktops, and other screenshot-based environments.
        </p>
        <ul className="mt-10 grid max-w-3xl gap-x-10 gap-y-3 sm:grid-cols-2">
          {surfaces.map((surface) => (
            <li className="flex items-center gap-3" key={surface}>
              <span
                aria-hidden="true"
                className="h-1.5 w-1.5 shrink-0 rounded-full bg-[#0F0E0D]"
              />
              <span className="text-base font-semibold leading-6">{surface}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

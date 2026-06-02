import Image from "next/image";

type DetectionRowProps = {
  color: string;
  label: string;
  value: string;
};

export function VisionPreview() {
  return (
    <div className="relative w-full min-w-0 max-w-full self-center">
      <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-lg bg-[#0F0E0D]" />
      <div className="relative w-full max-w-full overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC]">
        <div className="flex items-center justify-between border-b-2 border-[#0F0E0D] bg-white px-4 py-3">
          <div className="flex items-center gap-2">
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868]" />
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#F5D875]" />
            <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#B7E4C7]" />
          </div>
          <span className="text-sm font-semibold">vision frame</span>
        </div>
        <div className="grid min-w-0 gap-4 p-4 md:grid-cols-[170px_minmax(0,1fr)]">
          <div className="rounded-lg border-2 border-[#0F0E0D] bg-[#A8D5E8] p-3">
            {["Inbox", "Projects", "Search", "Settings"].map((item, index) => (
              <div
                className="relative mb-3 rounded-md border-2 border-[#0F0E0D] bg-white px-3 py-2 text-sm font-semibold last:mb-0"
                key={item}
              >
                {item}
                {index < 3 ? (
                  <span className="absolute -right-1 -top-1 rounded bg-[#EC7868] px-1.5 py-0.5 text-[10px] font-semibold">
                    id
                  </span>
                ) : null}
              </div>
            ))}
          </div>
          <div className="min-w-0 rounded-lg border-2 border-[#0F0E0D] bg-white p-4">
            <div className="mb-4 flex items-center gap-3">
              <Image
                src="/donkey-app-icon.png"
                alt=""
                width={52}
                height={52}
                className="rounded-lg border-2 border-[#0F0E0D]"
                priority
              />
              <div>
                <div className="text-lg font-semibold">Detected controls</div>
                <div className="text-sm text-[#666]">Boxes, labels, centers, IDs</div>
              </div>
            </div>
            <div className="grid gap-3">
              <DetectionRow color="bg-[#B7E4C7]" label="play button" value="639, 837" />
              <DetectionRow color="bg-[#F5D875]" label="next button" value="1290, 840" />
              <DetectionRow color="bg-[#F2B5C4]" label="search field" value="424, 112" />
            </div>
            <div className="mt-4 break-all rounded-md border-2 border-[#0F0E0D] bg-[#0F0E0D] p-3 font-mono text-xs leading-6 text-white">
              {`element: { id: "n8x2p0", label: "Next" }`}<br />
              {`box: [1248, 820, 84, 40]  point: [1290, 840]`}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function DetectionRow({ color, label, value }: DetectionRowProps) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-md border-2 border-[#0F0E0D] bg-[#FAF6EC] p-3">
      <div className="flex min-w-0 items-center gap-3">
        <span className={`h-7 w-7 shrink-0 rounded border-2 border-[#0F0E0D] ${color}`} />
        <span className="truncate text-sm font-semibold">{label}</span>
      </div>
      <span className="shrink-0 font-mono text-xs text-[#666]">{value}</span>
    </div>
  );
}

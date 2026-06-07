import type { VisionDataset } from "@/app/donkeyvision/visionData";

// Per-index palette (matches the worker overlay + the Mac app's vision overlay),
// so adjacent boxes read apart instead of sharing one color.
const PALETTE = [
  "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
  "#00C7BE", "#30B0C7", "#007AFF", "#5856D6",
  "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
];

function textOn(hex: string): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return 0.299 * r + 0.587 * g + 0.114 * b > 150 ? "#0F0E0D" : "#FFFFFF";
}

export function VisionOverlay({ dataset }: { dataset: VisionDataset }) {
  const { width: W, height: H, elements } = dataset;
  const fs = W / 85;
  return (
    <svg
      className="absolute inset-0 h-full w-full"
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      {elements.map((el, i) => {
        const color = PALETTE[i % PALETTE.length];
        const x = el.box[0] * W;
        const y = el.box[1] * H;
        const w = (el.box[2] - el.box[0]) * W;
        const h = (el.box[3] - el.box[1]) * H;
        const text = `AI ${el.label}`.slice(0, 26);
        const chipH = fs + 5;
        const chipW = text.length * fs * 0.56 + 6;
        const chipY = y - chipH >= 0 ? y - chipH : y;
        return (
          <g key={i}>
            <rect
              x={x}
              y={y}
              width={w}
              height={h}
              fill="none"
              stroke={color}
              strokeWidth={2}
              vectorEffect="non-scaling-stroke"
            />
            <rect x={x} y={chipY} width={chipW} height={chipH} fill={color} />
            <text
              x={x + 3}
              y={chipY + chipH - 4}
              fontSize={fs}
              fontFamily="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
              fontWeight={600}
              fill={textOn(color)}
            >
              {text}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

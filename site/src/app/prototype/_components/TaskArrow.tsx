type Props = {
  color: string;
  size?: number;
};

export function TaskArrow({ color, size = 14 }: Props) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" aria-hidden="true" className="flex-shrink-0">
      <path d="M3.1 1.1 12 7l-8.9 5.9L5.2 7 3.1 1.1Z" fill={color} />
    </svg>
  );
}

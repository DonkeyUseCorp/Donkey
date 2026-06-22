type Props = {
  color: string;
  size?: number;
  className?: string;
  silhouette?: boolean;
};

export function DonkeyCursor({ color, size = 28, className, silhouette = false }: Props) {
  return (
    <div className={`relative flex-shrink-0 ${className ?? ''}`} style={{ width: size, height: size }}>
      <svg
        viewBox="0 0 100 100"
        width={size}
        height={size}
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          filter: silhouette ? 'none' : 'drop-shadow(0 2px 4px rgba(0,0,0,0.34))',
          overflow: 'visible',
        }}
      >
        <path
          d="m83.086 5.6406-72.633 29.043c-7.6016 3.0391-7.1445 13.949 0.67969 16.344l24.562 7.5195c2.7539 0.84375 4.9102 3 5.7539 5.7539l7.5195 24.562c2.3984 7.8281 13.305 8.2812 16.344 0.67969l29.043-72.633c2.832-7.0781-4.1953-14.102-11.273-11.273z"
          fill={silhouette ? 'none' : color}
          stroke={silhouette ? 'rgba(255,255,255,0.5)' : 'rgba(255,255,255,0.92)'}
          strokeWidth={silhouette ? 6 : 5.36}
          strokeLinejoin="round"
        />
      </svg>
    </div>
  );
}

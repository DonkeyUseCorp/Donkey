import type { CSSProperties, ReactNode } from "react";
import Image from "next/image";
import {
  ArrowRight,
  Download,
  Folder,
  FolderInput,
  HardDriveDownload,
  MousePointer2,
  Rocket,
} from "lucide-react";

import {
  Headline,
  PillButton,
  SectionLabel,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { GITHUB_REPO_URL } from "@/app/_components/landing/data";
import {
  BG,
  BLACK,
  CARD,
  CORAL,
  type CardColor,
} from "@/app/_components/landing/theme";

type InstallVisualKind = "download" | "install" | "launch";

type InstallStep = {
  body: string;
  color: CardColor;
  eyebrow: string;
  icon: typeof Download;
  title: string;
  visual: InstallVisualKind;
};

const installSteps = [
  {
    eyebrow: "Step 1",
    title: "Open",
    body: "Open Donkey.dmg from your Downloads folder once the browser finishes.",
    color: "coral",
    icon: HardDriveDownload,
    visual: "download",
  },
  {
    eyebrow: "Step 2",
    title: "Install",
    body: "Drag Donkey into Applications in the installer window.",
    color: "blue",
    icon: FolderInput,
    visual: "install",
  },
  {
    eyebrow: "Step 3",
    title: "Launch",
    body: "Open Donkey from Applications, Launchpad, or the Dock.",
    color: "yellow",
    icon: Rocket,
    visual: "launch",
  },
] satisfies InstallStep[];

const iconSource = "/donkey-app-icon.png";

export function InstallInstructions() {
  return (
    <section
      style={{
        background: BG,
        color: BLACK,
        padding: "clamp(44px, 7vw, 88px) clamp(24px, 4vw, 48px) clamp(80px, 9vw, 128px)",
      }}
    >
      <div style={{ maxWidth: 1400, margin: "0 auto" }}>
        <SectionLabel number={1}>Install Donkey</SectionLabel>
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 440px), 1fr))",
            gap: 36,
            alignItems: "end",
          }}
        >
          <div>
            <Headline>
              Install Donkey
              <br />
              <span style={{ fontStyle: "italic" }}>on your Mac.</span>
            </Headline>
          </div>
          <div>
            <p
              style={{
                color: "#454545",
                fontSize: "clamp(16px, 1.8vw, 18px)",
                lineHeight: 1.6,
                margin: "0 0 22px",
                maxWidth: 560,
              }}
            >
              Donkey ships as a standard macOS disk image. Download the DMG,
              drag the app into Applications, then launch it like any other Mac
              app.
            </p>
            <PillButton href={GITHUB_REPO_URL} variant="primary" size="lg">
              Download for Mac <ArrowRight size={18} />
            </PillButton>
          </div>
        </div>

        <div
          style={{
            marginTop: 48,
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 330px), 1fr))",
            gap: 18,
          }}
        >
          {installSteps.map((step) => (
            <InstallStepCard key={step.title} step={step} />
          ))}
        </div>
      </div>
    </section>
  );
}

type InstallStepCardProps = {
  step: InstallStep;
};

function InstallStepCard({ step }: InstallStepCardProps) {
  const Icon = step.icon;

  return (
    <TapedCard color="cream" shadowColor={step.color} tapeColor={step.color}>
      <article style={{ minWidth: 0, overflow: "hidden" }}>
        <InstallVisual kind={step.visual} />
        <div style={{ padding: "24px 24px 28px" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 10,
              color: "#5c554b",
              fontSize: 14,
              fontWeight: 800,
              marginBottom: 16,
            }}
          >
            <Icon size={17} />
            {step.eyebrow}
          </div>
          <h3
            style={{
              fontSize: 32,
              lineHeight: 1,
              fontWeight: 900,
              margin: "0 0 14px",
            }}
          >
            {step.title}
          </h3>
          <p
            style={{
              color: "#454545",
              fontSize: 16,
              lineHeight: 1.5,
              margin: 0,
            }}
          >
            {step.body}
          </p>
        </div>
      </article>
    </TapedCard>
  );
}

type InstallVisualProps = {
  kind: InstallVisualKind;
};

function InstallVisual({ kind }: InstallVisualProps) {
  const visuals: Record<InstallVisualKind, ReactNode> = {
    download: <DownloadVisual />,
    install: <InstallVisualDrag />,
    launch: <LaunchVisual />,
  };

  return <div style={visualFrameStyle}>{visuals[kind]}</div>;
}

const visualFrameStyle: CSSProperties = {
  position: "relative",
  height: 240,
  background: "#111110",
  borderBottom: "1px solid rgba(255,255,255,0.12)",
  overflow: "hidden",
};

function DownloadVisual() {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        padding: 28,
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: "30px 28px auto",
          height: 72,
          borderRadius: 18,
          border: "1px solid rgba(255,255,255,0.16)",
          background: "#22211f",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 28,
          right: 28,
          top: 88,
          height: 2,
          background: "rgba(255,255,255,0.14)",
        }}
      />
      <div
        style={{
          position: "absolute",
          right: 48,
          top: 74,
          width: 58,
          height: 58,
          borderRadius: "50%",
          background: "rgba(236,120,104,0.14)",
          border: "1px solid rgba(236,120,104,0.5)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Download color="#fff" size={24} />
      </div>
      <div
        style={{
          position: "absolute",
          left: 44,
          right: 44,
          bottom: 34,
          minHeight: 76,
          borderRadius: 16,
          background: "#2b2926",
          boxShadow: "0 18px 45px rgba(0,0,0,0.35)",
          display: "flex",
          alignItems: "center",
          gap: 16,
          padding: "16px 18px",
        }}
      >
        <div
          style={{
            width: 36,
            height: 46,
            borderRadius: 5,
            background: CARD.white,
            color: BLACK,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            flexShrink: 0,
          }}
        >
          <HardDriveDownload size={19} />
        </div>
        <div style={{ minWidth: 0 }}>
          <div
            style={{
              color: "#fff",
              fontSize: 18,
              fontWeight: 900,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            Donkey.dmg
          </div>
          <div style={{ color: "rgba(255,255,255,0.54)", fontSize: 13 }}>
            Download complete
          </div>
        </div>
        <CursorBadge style={{ marginLeft: "auto", alignSelf: "flex-end" }} />
      </div>
    </div>
  );
}

function InstallVisualDrag() {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: "clamp(12px, 5vw, 30px)",
      }}
    >
      <div style={{ position: "relative" }}>
        <AppIcon alt="Donkey app icon" size={72} />
        <CursorBadge
          style={{
            position: "absolute",
            right: -12,
            bottom: -10,
          }}
        />
      </div>
      <div
        aria-hidden="true"
        style={{
          width: 56,
          height: 30,
          borderBottom: "3px solid rgba(255,255,255,0.22)",
          borderRight: "3px solid rgba(255,255,255,0.22)",
          borderRadius: "0 0 44px 0",
          transform: "translateY(16px) rotate(-8deg)",
        }}
      />
      <div
        style={{
          width: 108,
          height: 108,
          borderRadius: 18,
          border: "2px dashed rgba(255,255,255,0.16)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <MacFolder />
      </div>
    </div>
  );
}

function LaunchVisual() {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          position: "absolute",
          top: 44,
          left: "50%",
          transform: "translateX(-50%)",
          borderRadius: 8,
          background: CARD.white,
          color: BLACK,
          fontSize: 15,
          fontWeight: 800,
          padding: "7px 12px",
          boxShadow: "0 12px 30px rgba(0,0,0,0.24)",
        }}
      >
        Donkey
      </div>
      <div
        style={{
          width: "min(94%, 390px)",
          boxSizing: "border-box",
          minHeight: 98,
          borderRadius: 28,
          background: "rgba(255,255,255,0.32)",
          border: "1px solid rgba(255,255,255,0.18)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: "clamp(8px, 2vw, 16px)",
          padding: "clamp(10px, 2vw, 16px)",
        }}
      >
        <FinderIcon />
        <SafariIcon />
        <div style={{ position: "relative" }}>
          <AppIcon alt="" size={52} />
          <CursorBadge
            style={{
              position: "absolute",
              right: -14,
              bottom: -12,
            }}
          />
        </div>
        <MacFolder compact />
      </div>
    </div>
  );
}

type AppIconProps = {
  alt: string;
  size: number;
};

function AppIcon({ alt, size }: AppIconProps) {
  return (
    <Image
      alt={alt}
      height={size}
      src={iconSource}
      style={{
        display: "block",
        width: size,
        height: size,
        borderRadius: Math.max(12, Math.round(size * 0.22)),
        boxShadow: "0 16px 34px rgba(0,0,0,0.32)",
      }}
      width={size}
    />
  );
}

type MacFolderProps = {
  compact?: boolean;
};

function MacFolder({ compact = false }: MacFolderProps) {
  const width = compact ? 54 : 86;
  const height = compact ? 44 : 64;

  return (
    <div
      aria-hidden="true"
      style={{
        position: "relative",
        width,
        height,
        borderRadius: compact ? 12 : 14,
        background: "linear-gradient(180deg, #8fd2ff 0%, #55aceb 100%)",
        boxShadow: "0 16px 30px rgba(0,0,0,0.24)",
      }}
    >
      <div
        style={{
          position: "absolute",
          top: -10,
          left: 8,
          width: compact ? 24 : 38,
          height: 16,
          borderRadius: "8px 10px 0 0",
          background: "#7fc6f5",
        }}
      />
      <Folder
        color="rgba(15,14,13,0.34)"
        size={compact ? 24 : 40}
        strokeWidth={2.4}
        style={{
          position: "absolute",
          left: "50%",
          top: "50%",
          transform: "translate(-50%, -44%)",
        }}
      />
    </div>
  );
}

function FinderIcon() {
  return (
    <div
      aria-hidden="true"
      style={{
        width: 52,
        height: 52,
        borderRadius: 14,
        background: "linear-gradient(90deg, #64b5ff 0 50%, #eef7ff 50% 100%)",
        position: "relative",
        boxShadow: "0 12px 24px rgba(0,0,0,0.2)",
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 13,
          top: 15,
          width: 4,
          height: 8,
          borderRadius: 4,
          background: BLACK,
        }}
      />
      <div
        style={{
          position: "absolute",
          right: 14,
          top: 15,
          width: 4,
          height: 8,
          borderRadius: 4,
          background: BLACK,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 14,
          right: 14,
          bottom: 14,
          height: 10,
          borderBottom: `3px solid ${BLACK}`,
          borderRadius: "0 0 24px 24px",
        }}
      />
    </div>
  );
}

function SafariIcon() {
  return (
    <div
      aria-hidden="true"
      style={{
        width: 52,
        height: 52,
        borderRadius: 14,
        background: "radial-gradient(circle at 50% 50%, #f8fbff 0 36%, #67b7ff 37% 100%)",
        position: "relative",
        boxShadow: "0 12px 24px rgba(0,0,0,0.2)",
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 24,
          top: 9,
          width: 5,
          height: 34,
          borderRadius: 4,
          background: CORAL,
          transform: "rotate(42deg)",
          transformOrigin: "50% 50%",
        }}
      />
      <div
        style={{
          position: "absolute",
          inset: 7,
          borderRadius: "50%",
          border: "2px solid rgba(255,255,255,0.74)",
        }}
      />
    </div>
  );
}

type CursorBadgeProps = {
  style?: CSSProperties;
};

function CursorBadge({ style }: CursorBadgeProps) {
  return (
    <div
      aria-hidden="true"
      style={{
        width: 32,
        height: 32,
        borderRadius: "50%",
        background: CARD.white,
        border: `2px solid ${BLACK}`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: "0 10px 18px rgba(0,0,0,0.28)",
        ...style,
      }}
    >
      <MousePointer2 color={BLACK} fill={BLACK} size={17} />
    </div>
  );
}

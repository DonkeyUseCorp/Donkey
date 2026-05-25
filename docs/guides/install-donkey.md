# Install Donkey Locally

Donkey can be packaged into a local macOS app bundle and drag-to-Applications disk image for manual testing or site distribution.

From the repo root:

```bash
./scripts/package-donkey-app.sh
```

The drag-to-Applications background is rendered from SVG, so local packaging
requires ImageMagick's `magick` command.

The script builds the release executable, creates `dist/Donkey.app`, copies bundled resources and embedded frameworks, ensures the executable can load those frameworks from the app bundle, applies an ad-hoc signature when `codesign` is available, and creates `dist/Donkey.dmg`.

The app bundle version defaults to `0.1.0` build `1`. Override it for local release testing:

```bash
DONKEY_APP_VERSION="0.1.1" \
DONKEY_APP_BUILD="2" \
./scripts/package-donkey-app.sh
```

The app bundle registers the `donkey://auth/callback` sign-in callback and
opens the site `/mac-auth` handoff for Google OAuth before the overlay starts.
Packaged apps point auth and hosted inference at the same base URL:
`https://donkeyuse.com` by default.

Override the single base URL for local or staging testing:

```bash
DONKEY_WEB_BASE_URL="http://localhost:3000" ./scripts/package-donkey-app.sh
```

For local distribution testing, publish the disk image:

```text
dist/Donkey.dmg
```

Opening the disk image mounts a `Donkey` volume with a custom Finder installer
window: `Donkey.app` sits on the left, the `Applications` shortcut sits on the
right, and the background arrow points users through the drag-to-Applications
flow. The installer artwork lives in `scripts/assets/donkey-dmg-background.svg`;
the package script renders that SVG into the Finder background and writes the
Finder layout into the compressed disk image so users see the install screen
immediately after opening `Donkey.dmg`.
The user installs Donkey by dragging the app onto the shortcut, which copies it
into `/Applications`.

To launch the packaged app:

```bash
open dist/Donkey.app
```

To test the installer flow:

```bash
open dist/Donkey.dmg
```

## Sparkle Updates

Donkey uses Sparkle for app updates. Do not add a Donkey-specific update installer or custom replacement flow; Sparkle owns appcast parsing, update validation, download, install, relaunch, and user-facing update UI.

Production releases are distributed from GitHub Releases. See
`docs/guides/releasing-donkey.md` for the release runbook. Do not use the
Supabase Storage `/release` bucket for release binaries or appcast hosting.

The public Sparkle feed lives in `site/public/appcast.xml`, which the site
serves as `https://donkeyuse.com/appcast.xml`. Appcast enclosure URLs point to
the numeric GitHub Release asset URL, not a moving `latest` or `-latest` URL.

Configure Sparkle when packaging:

```bash
DONKEY_APP_VERSION="0.1.1" \
DONKEY_APP_BUILD="2" \
DONKEY_SPARKLE_FEED_URL="https://donkeyuse.com/appcast.xml" \
DONKEY_SPARKLE_PUBLIC_ED_KEY="..." \
./scripts/package-donkey-app.sh
```

For local update testing, use Sparkle's standard local appcast workflow:

1. Package the older app and install it in `/Applications`.
2. Package the newer app with a higher `DONKEY_APP_VERSION` / `DONKEY_APP_BUILD`.
3. Use Sparkle's `generate_appcast` tooling over the folder containing the newer update archive.
4. Package or launch the older app with `DONKEY_SPARKLE_FEED_URL` pointing to the local `file://` appcast and `DONKEY_SPARKLE_PUBLIC_ED_KEY` set to the matching public EdDSA key.

Example feed URL shape:

```bash
DONKEY_SPARKLE_FEED_URL="file:///Users/me/donkey-updates/appcast.xml"
```

When Sparkle finds a valid signed update, the expanded notch task panel shows an update button in its header. Clicking it invokes Sparkle's standard update UI.

## Hosted Models

The packaged Mac app does not bundle, download, install, or configure local
model weights. Model-backed behavior is routed through the authenticated Donkey
backend, which owns provider credentials, provider selection, and concrete model
selection. The Mac client sends typed requests to the backend and does not need
OpenAI, Gemini, or other provider API keys.

First launch setup is therefore an account and permission setup flow, not a
local model installer. After sign-in, Donkey asks for Accessibility,
Screenshots, and Microphone with user-visible reasons before starting the
overlay. Protected folders such as Desktop, Documents, and Downloads remain
lazy and are requested only when a user-requested local-item lookup needs them.
There are no supported release manifest URLs, model weight override URLs, local
LLM packages, or local model repair steps in the hosted-model install path.

## Local Development

For local development, `scripts/run-donkey-dev.sh` starts the local site when
`DONKEY_WEB_BASE_URL` points at localhost, builds Donkey, wraps the debug
executable in `apps/Donkey/.build/debug/Donkey.app`, registers that app bundle
for `donkey://auth/callback`, and launches it. The debug wrapper uses the
`Donkey Dev` display name and `ai.donkey.Donkey.dev` bundle identifier by
default so macOS privacy settings do not collide with packaged `Donkey.app`
builds.

```bash
./scripts/run-donkey-dev.sh
```

Use `DONKEY_START_SITE=0` to skip starting the site, `DONKEY_LAUNCH_APP=0` to
build and register the debug app without opening it, or `DONKEY_WEB_BASE_URL` /
`DONKEY_AUTH_CALLBACK_SCHEME` to test a different auth handoff. Set
`DONKEY_CODESIGN_IDENTITY` to a local code-signing identity when you want macOS
privacy grants to survive debug rebuilds; without one, the script falls back to
ad-hoc signing.

Development builds use the same hosted-model boundary as packaged builds. If a
developer needs to test provider behavior, configure the site/backend
environment and keep provider credentials out of the Mac app.

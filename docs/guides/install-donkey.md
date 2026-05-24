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
DONKEY_APP_VERSION="0.1.1" DONKEY_APP_BUILD="2" ./scripts/package-donkey-app.sh
```

The app bundle registers the `donkey://auth/callback` sign-in callback and
opens the site `/mac-auth` handoff for Google OAuth before the overlay starts.
Packaged apps point auth and hosted inference at `https://donkeyuse.com` by
default. Override the web base URL only for local or staging testing:

```bash
DONKEY_WEB_BASE_URL="http://localhost:3000" ./scripts/package-donkey-app.sh
```

If hosted inference is served from a different origin than auth, set
`DONKEY_BACKEND_URL`; otherwise the packaged app uses `DONKEY_WEB_BASE_URL` for
both:

```bash
DONKEY_WEB_BASE_URL="https://staging.example" \
DONKEY_BACKEND_URL="https://api.staging.example" \
./scripts/package-donkey-app.sh
```

For distribution through the site, publish the disk image:

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

Configure Sparkle when packaging:

```bash
DONKEY_APP_VERSION="0.1.1" \
DONKEY_APP_BUILD="2" \
DONKEY_SPARKLE_FEED_URL="https://example.com/donkey/appcast.xml" \
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
local model installer. There are no supported release manifest URLs, model
weight override URLs, local LLM packages, or local model repair steps in the
hosted-model install path.

## Local Development

For local development, `scripts/run-donkey-dev.sh` builds and launches the debug app:

```bash
./scripts/run-donkey-dev.sh
```

Development builds use the same hosted-model boundary as packaged builds. If a
developer needs to test provider behavior, configure the site/backend
environment and keep provider credentials out of the Mac app.

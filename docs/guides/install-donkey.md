# Install Donkey Locally

Donkey can be packaged into a local macOS app bundle and drag-to-Applications disk image for manual testing or site distribution.

From the repo root:

```bash
./scripts/package-donkey-app.sh
```

The script builds the release executable, creates `dist/Donkey.app`, copies bundled resources and embedded frameworks, ensures the executable can load those frameworks from the app bundle, applies an ad-hoc signature when `codesign` is available, and creates `dist/Donkey.dmg`.

The app bundle version defaults to `0.1.0` build `1`. Override it for local release testing:

```bash
DONKEY_APP_VERSION="0.1.1" DONKEY_APP_BUILD="2" ./scripts/package-donkey-app.sh
```

The app bundle registers the `donkey://auth/callback` sign-in callback and
opens the site `/mac-auth` handoff for Google OAuth before the overlay starts.
Packaged apps point at `https://donkeyuse.com` by default. Override the web base
URL only for local or staging auth testing:

```bash
DONKEY_WEB_BASE_URL="http://localhost:3000" ./scripts/package-donkey-app.sh
```

For distribution through the site, publish the disk image:

```text
dist/Donkey.dmg
```

Opening the disk image mounts a `Donkey` volume with `Donkey.app` and an `Applications` shortcut, matching the standard drag-to-Applications macOS install flow. The user installs Donkey by dragging the app onto the shortcut, which copies it into `/Applications`.

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

The package script also creates Donkey-compatible sidecar runner packages under:

```text
dist/LocalRuntimePackages/
```

These package folders are release artifacts to host outside the app. App packages do not include local runtime packages. On setup, Donkey downloads the configured manifest-backed package, installs it fresh into Application Support, then the sidecar creates a managed virtual environment and installs manifest-tracked Python requirements from the Python package index.

Configure hosted runtime manifest URLs when packaging:

```bash
DONKEY_RUNTIME_PACKAGE_BASE_URL="https://example.com/donkey/runtimes" \
DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS="parakeet-transcriber=https://example.com/donkey/runtimes/parakeet-transcriber/manifest.json,yolo-segmenter=https://example.com/donkey/runtimes/yolo-segmenter/manifest.json,ui-understander=https://example.com/donkey/runtimes/ui-understander/manifest.json,local-llm=https://example.com/donkey/runtimes/local-llm/manifest.json" \
./scripts/package-donkey-app.sh
```

On first launch, Donkey opens setup and starts installing required local runtimes. Setup downloads the configured sidecar packages, verifies their manifests/checksums/signatures, registers them in Application Support, asks them to prepare model weights, and health-checks them. The packages do not include model weights; they contain protocol-speaking runner entrypoints for the local command parser, Parakeet voice transcription, and YOLO screenshot segmentation. UI understanding ships as a local Swift sidecar that uses Apple's on-device Vision text recognition and does not need downloaded model weights. If setup fails, clicking the same button retries failed or not-yet-attempted runtimes while keeping completed installs. The setup window can also be reopened from the app settings.

Each sidecar supports setup-time model weight preparation. During setup, Donkey calls the sidecar with `prepareModelWeights`; the sidecar downloads or warms the configured model cache and reports cached/downloaded status before health check. The local command-parser LLM is setup-managed too: Donkey packages a `local-llm` sidecar whose release manifest must include a model-weight download URL, checksum, and local inference backend requirement. The default package uses a Donkey-managed GGUF weight download with a source-built CPU `llama-cpp-python` backend so command parsing does not depend on Metal availability, and its health check loads a real model context rather than only importing the Python package. Actionable prompt turns are parsed through `DONKEY_LOCAL_LLM_RUNNER`; if that local runtime is unavailable, task-intent parsing fails clearly. Donkey does not fall back to a user-managed Ollama daemon. The Parakeet runner can fetch the Hugging Face snapshot when `huggingface_hub` is available and transcribes through NVIDIA NeMo when the local Python backend is installed.

The packaged local command-parser model lives in
`config/local-llm-models.json`. Change that file when updating the product
default; packaging and dev runtime refresh both read it. Eval-only candidate
lists live with the eval fixtures under `evals/task-intent/`. Set
`DONKEY_LOCAL_LLM_MODEL_CONFIG` to test a different runtime-default config file.

Override model-weight URLs when packaging:

```bash
DONKEY_PARAKEET_MODEL_URL="https://..." \
DONKEY_PARAKEET_MODEL_SHA256="..." \
DONKEY_YOLO_MODEL_URL="https://..." \
DONKEY_YOLO_MODEL_SHA256="..." \
DONKEY_LOCAL_LLM_MODEL_ID="qwen2.5-0.5b-instruct-q4_k_m" \
DONKEY_LOCAL_LLM_MODEL_URL="https://..." \
DONKEY_LOCAL_LLM_MODEL_SHA256="..." \
./scripts/package-donkey-app.sh
```

Release runtime manifests can be verified with Curve25519 signing keys embedded
in the app bundle. Provide trusted public keys as comma-separated
`key-id=base64-public-key` pairs and set strict verification when packaging a
release build:

```bash
DONKEY_RUNTIME_MANIFEST_PUBLIC_KEYS="runtime-release-v1=..." \
DONKEY_RUNTIME_REQUIRE_CRYPTO_SIGNATURES="1" \
./scripts/package-donkey-app.sh
```

If a model URL/backend is missing for a sidecar or Parakeet's local Python backend is missing, setup or runtime calls fail clearly with a retryable needs-attention state instead of pretending the runtime is usable.

## Dev Runtime Manifests

For local development, `scripts/run-donkey-dev.sh` bootstraps local runtime packages and manifest files from `dist/LocalRuntimePackages/` before launching the debug app:

```bash
./scripts/run-donkey-dev.sh
```

If runtime packages are missing, stale, or still have the old local-LLM package without a model URL/checksum/backend requirement, the dev runner calls `scripts/package-donkey-app.sh` first. It then regenerates the dev manifest env file and loads it for the debug launch.

The dev runner automatically creates and loads:

```text
dist/donkey-dev-runtime-manifests.env
```

That env file points `DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS` at generated `file://` manifests under `dist/LocalRuntimeDevManifests/`. Those dev manifests rewrite each runtime file entry to a local `file://` download URL, so the debug app can install runtimes into Application Support without first installing `/Applications/Donkey.app`.

After building the debug executable, `run-donkey-dev.sh` runs `scripts/setup-dev-local-runtimes.py`. The helper installs any missing, invalid, or stale-version local runtime packages into Application Support, then asks newly installed sidecars to prepare model weights and run a health check. For `local-llm`, that first prepare pass may create a managed Python environment, install `llama-cpp-python`, and download the configured GGUF model file; this is foreground work, not a silent background repair. Already-current runtime registrations are left alone, so the setup pass is a one-time dev bootstrap unless local packages change. Runtime setup failures are reported as warnings and the debug app still launches.

To regenerate the env file manually:

```bash
scripts/create-dev-runtime-manifests.py
```

Set `DONKEY_DEV_RUNTIME_AUTO_PACKAGE=0` to skip automatic package refresh. Set `DONKEY_DEV_RUNTIME_PACKAGE_REFRESH=1` to force a package refresh before launch. Set `DONKEY_DEV_RUNTIME_MANIFESTS=0` to make `run-donkey-dev.sh` skip manifest generation. Set `DONKEY_DEV_RUNTIME_SETUP=0` to skip the missing-runtime setup pass. Set `DONKEY_DEV_RUNTIME_PREPARE=0` to install/register missing packages without running model preparation or health checks. Set `DONKEY_DEV_RUNTIME_FORCE_SETUP=1` to reinstall from the dev manifests even when the registry already points at the same runtime version. Set `DONKEY_DEV_RUNTIME_ENV_FILE`, `DONKEY_DEV_RUNTIME_PACKAGE_DIR`, or `DONKEY_DEV_RUNTIME_BASE_DIR` to use different local paths.

Developer diagnostics:

```bash
swift run Donkey -- --local-runtime-status
swift run Donkey -- --local-runtime-support
swift run Donkey -- --repair-local-runtime --runtime-id yolo-segmenter
swift run Donkey -- --remove-local-runtime --runtime-id yolo-segmenter
```

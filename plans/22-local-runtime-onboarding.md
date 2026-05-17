# Local Runtime Onboarding Plan

This plan captures the installer and onboarding work Donkey should borrow from OpenWhispr's local model setup, adapted to Donkey's generic sidecar architecture.

OpenWhispr is stronger today at productized local transcription setup: it has packaged native binaries, a settings/control-panel flow, first-use model download, model choices, installation rechecks, and clear troubleshooting. Donkey should borrow those product patterns without copying the speech-app architecture. Donkey's local runtimes must remain generic sidecars that produce transcripts, observations, masks, memory proposals, or planner hints, never direct input actions.

## Goal

Make local model runtime setup feel like a normal post-install app flow:

1. Donkey ships without model weights.
2. The app exposes one setup action that downloads the compatible runtime packages.
3. Donkey validates expected executables, records them in Application Support, and health-checks them.
4. Users do not need to choose model folders or understand runtime-specific setup.
5. Sidecar execution works without users exporting shell environment variables.
6. If setup fails, users can retry the same setup action; already completed runtime installs are kept, failed or not-yet-attempted runtimes are retried, and repair, upgrade, and support diagnostics can exist behind that simple flow rather than as first-run choices.

## Borrow From OpenWhispr

- First-run setup UI for local model runtimes.
- One first-run setup button that performs download, validation, installation, registration, and health checks.
- Internal model/package status states for diagnostics: missing, downloading, installed, invalid, health-check failed, upgrade available.
- Checksum and signature validation for downloaded packages.
- Automatic installation recheck as part of setup and repair.
- Published runtime packages separate from the main app.
- Explicit cache/package locations.
- Troubleshooting copy for permissions, disk space, stale binaries, and slow performance.

## Donkey-Specific Design

Donkey should keep its current generic sidecar boundary:

- Parakeet sidecar returns transcript text only.
- YOLO sidecar returns segmentation masks only.
- UI-understanding sidecar returns visible text, controls, form fields, and confidence only.
- Sidecar output feeds observation, transcript, memory proposal, or planner-hint paths only.
- The action engine remains the only owner of OS input.

The app-managed runtime registry remains under:

```text
~/Library/Application Support/Donkey/LocalModelRuntimes/runtime-installations.json
```

Developer environment variables remain supported as overrides:

```text
DONKEY_PARAKEET_TRANSCRIBER
DONKEY_YOLO_SEGMENTER
DONKEY_UI_UNDERSTANDER
```

## Implementation Slices

### 1. Runtime Package Manifest

Define a signed manifest format for each runtime package:

- runtime id
- runtime version
- model id/version
- platform and architecture
- executable relative path
- model file relative paths
- expected SHA-256 hashes
- minimum Donkey version
- sidecar protocol version
- download URL
- release notes URL

Donkey rejects a package when the manifest is missing, unsigned, unsupported, mismatched, missing its executable, or hash-invalid. The current implementation enforces SHA-256 checksums and requires signature metadata. Cryptographic signature verification can be strengthened once the release signing key is finalized.

### 2. First-Run Setup UI

Add a small runtime setup surface reachable on first launch and from settings:

- Shows one overall setup state and one primary setup button.
- The setup button downloads, verifies, installs, registers, and health-checks all required runtimes.
- Failed setup returns to a retryable state with the same single button. Retry keeps completed runtimes and resumes at failed or not-yet-attempted runtimes.
- Explains that model weights are not bundled with the app.
- Does not expose per-runtime controls during first-run setup.
- Does not block typed-command MVP unless the requested feature needs the missing runtime.

### 3. Download And Install Flow

Support app-driven downloads where possible:

- Download to a temporary Application Support staging directory.
- Verify checksum and required signature metadata before registration.
- Move verified package files into a managed runtime directory.
- Mark executable permissions when needed.
- Record the installation in the runtime registry.
- Delete partial downloads after failure.

Manual folder registration remains available through developer launch arguments only.

### 4. Health Checks

Each runtime package should expose a cheap health command through the same process boundary:

```json
{"operation":"healthCheck","protocolVersion":"v1"}
```

Expected response:

```json
{
  "status": "ok",
  "runtimeID": "...",
  "runtimeVersion": "...",
  "modelID": "...",
  "protocolVersion": "v1",
  "metadata": {}
}
```

Health-check failures produce actionable status metadata and do not silently fall back.

### 5. Upgrade And Repair

Add runtime lifecycle operations:

- check for updates from the manifest channel
- download update
- verify before replacing current runtime
- keep one previous good runtime until new runtime health-checks pass
- rollback on failed install
- remove runtime and clear registry entry

### 6. Reporting And Support

Expose setup evidence in reports:

- installed runtime versions
- health-check status
- executable path source: env override or app registry
- package hash status
- model version
- protocol version

Add a support/debug export that omits user data and includes runtime setup status.

## Acceptance Criteria

- A fresh Donkey install can show local runtime setup instructions without Terminal env vars. Supported.
- A user can start app-managed runtime setup from one first-run button. Supported.
- Donkey refuses missing, non-executable, mismatched, unsigned, or hash-invalid runtime packages. Supported for executable presence, signature metadata, platform/architecture/runtime mismatch, and SHA-256 file hashes.
- Sidecar calls resolve registered executables from Application Support when env vars are absent. Supported.
- The first-run setup window avoids per-runtime customization and reports one overall ready or needs-attention state. Supported.
- `swift test` covers manifest validation, package download, checksum/signature enforcement, managed cache install, registration, health recheck, and app-registry sidecar resolution. Supported.
- Docs explain that model weights are downloaded after install and are not bundled in the app. Supported.

## Current Code Boundary

Already supported:

- `LocalModelRuntimeSetupManager` runtime specs, setup instructions, registration, status, and app-managed executable resolution.
- First-run local runtime setup window with one setup button that drives download, validation, install, registration, and health checks.
- Manifest-backed package download and managed cache install under Application Support.
- SHA-256 package file validation and required signature metadata.
- Sidecar health-check protocol through the existing JSON process runner.
- `ProcessBackedLocalJSONSidecarRunner` env-first then app-registry executable lookup.
- Debug commands:
  - `--local-runtime-instructions`
  - `--install-local-runtime --runtime-id <id> --runtime-source <folder>`
  - `--local-runtime-status`

Still needed:

- Publish real Donkey-compatible runtime package manifests and downloadable files.
- Finalize cryptographic signature verification with release signing keys.
- Settings-menu entry to reopen the setup window after first launch.
- Behind-the-scenes upgrade/repair/remove flows.
- Support/debug export.

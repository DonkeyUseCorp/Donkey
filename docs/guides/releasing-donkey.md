# Releasing Donkey

Donkey production releases are distributed through GitHub Releases, built by
the `Release Donkey` GitHub Actions workflow from the latest default-branch
code. A separate `Nightly Donkey Build` workflow publishes a smoke-test
prerelease on a schedule. The Supabase Storage `/release` bucket is not part
of the release path.

**The one rule:** user-facing links use the immutable numeric tag. The website
download URL and the appcast enclosure URL point at
`/releases/download/vMAJOR.MINOR.PATCH/Donkey.dmg`, never a moving `latest` or
`-latest` URL. Alias tags exist only for maintainer convenience.

## Workflows

| | `Release Donkey` | `Nightly Donkey Build` |
|---|---|---|
| Trigger | manual: choose `patch`, `minor`, or `major` | nightly at 09:00 UTC, plus manual |
| Tag | numeric SemVer `vMAJOR.MINOR.PATCH` (starts at `0.1.0`) | moving `nightly` tag |
| Release | numeric GitHub Release, marked GitHub's latest | `Donkey Nightly Build` prerelease |
| Assets | `Donkey.dmg` + `Donkey.dmg.sha256` | `Donkey.dmg` + `Donkey.dmg.sha256` |
| Appcast / website | updates `site/public/appcast.xml` and the website download constant, commits both | untouched |
| Alias tags | moves `vMAJOR`, `vMAJOR.MINOR`, `latest` | untouched |
| Retention | keeps the latest 10 numeric releases; deletes older release records (never tags or the nightly prerelease) | n/a |
| Skip condition | none | skips when the `nightly` tag already points at the default-branch commit |

Use nightly builds to smoke-test the latest default-branch app package. Use
`Release Donkey` to publish a user-facing release.

## Release Runbook

1. Open GitHub Actions for the repository.
2. Select `Release Donkey`.
3. Click `Run workflow`.
4. Choose `patch`, `minor`, or `major`.
5. Run the workflow.

The workflow checks out the latest default branch, derives the next version
from existing numeric release tags and the selected bump, builds and packages
`dist/Donkey.dmg`, Developer ID-signs and notarizes the app and disk image and
signs the DMG with the Sparkle private key, creates or updates the numeric
GitHub Release with the DMG and checksum, updates `site/public/appcast.xml` and
the website download constant and commits those changes, marks the release as
GitHub's latest, moves the alias tags, and prunes releases beyond the latest 10.

The app's Developer ID signing + notarization reuses the same secrets as the
bundled tools (see below); without them the release falls back to an ad-hoc
signed app that is not distributable. The app is signed with the hardened
runtime and the Apple Events entitlement (`scripts/assets/donkey.entitlements`)
it needs to keep automating other apps once hardened.

## Bundled Tools

The capability skills (media, pdf) run CLI tools — `ffmpeg`, `yt-dlp`, and a few
others — that the app downloads on first launch instead of baking into the app
download. The `Publish Bundled Tools` workflow builds them from source on an
arm64 runner, signs and notarizes them, uploads the bundle as a GitHub release
asset, and commits the refreshed `bundled-tools.json` (the manifest the app reads
to know what to fetch). It runs on demand and whenever the tools recipe changes.

Every tool is re-signed during the build: relocating their bundled libraries
invalidates the original signature, and macOS will not run an unsigned binary on
Apple Silicon. Without the secrets below the tools are only ad-hoc signed — fine
for local development, not for distribution.

Standalone CLI binaries cannot be stapled (only app/dmg/pkg bundles can), so
notarization here is the online proof that the Developer ID signature is good;
the signature itself is what lets the downloaded tools run.

### Obtaining the signing secrets

Everything comes from two things created in your Apple Developer account (paid
program required; the certificate can only be created by the account
Holder/Admin). An **Apple Development** certificate is the wrong kind — Gatekeeper
and notarytool reject it; you need **Developer ID Application**.

1. **Developer ID Application certificate.** Create it in Xcode: Settings →
   Accounts → your team → Manage Certificates → `+` → Developer ID Application. It
   installs into your login keychain (it is not downloaded as a file). In Keychain
   Access, expand it to reveal its private key, select **both**, and export a
   `.p12` (you choose the password). `security find-identity -v -p codesigning`
   prints the identity string.
   - `DONKEY_DEVELOPER_ID_CERT_P12` = `base64 -i cert.p12`
   - `DONKEY_DEVELOPER_ID_CERT_PASSWORD` = the export password
   - `DONKEY_TOOLS_SIGN_IDENTITY` = the identity, e.g. `Developer ID Application: Name (TEAMID)`
2. **App Store Connect API key** (notarization), from App Store Connect → Users
   and Access → Integrations → App Store Connect API. Download the `.p8` (offered
   once) and read the Key ID and Issuer ID off the page.
   - `DONKEY_NOTARY_KEY_P8` = `base64 -i AuthKey_XXXX.p8`
   - `DONKEY_NOTARY_KEY_ID` = the key's Key ID
   - `DONKEY_NOTARY_ISSUER_ID` = the Issuer ID

Before adding the secrets, confirm you have the right certificate:
`security find-identity -v -p codesigning` should list a `Developer ID
Application` line — an Apple Development cert will not work.

## One-Time Sparkle Setup

Generate one Sparkle EdDSA signing keypair on a trusted Mac:

```bash
apps/Donkey/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account donkey
```

Copy the printed `SUPublicEDKey` value into the GitHub repository secret
`DONKEY_SPARKLE_PUBLIC_ED_KEY`. Then export the matching private key:

```bash
apps/Donkey/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account donkey \
  -x /tmp/donkey-sparkle-private-key.txt
```

Copy the file contents into the GitHub repository secret
`DONKEY_SPARKLE_PRIVATE_ED_KEY`, then delete the exported file:

```bash
rm -f /tmp/donkey-sparkle-private-key.txt
```

Keep this keypair stable. Already-installed apps trust the public key embedded
at packaging time and reject future updates signed by a different private key.
Sparkle signs and validates update archives; do not add a Donkey-specific
updater or replacement installer.

## Verification

After the workflow finishes:

- The GitHub Release for `vMAJOR.MINOR.PATCH` contains `Donkey.dmg` and
  `Donkey.dmg.sha256`.
- The website source has `DONKEY_LATEST_VERSION` set to the numeric version.
- `site/public/appcast.xml` contains one item for that version and an
  enclosure URL under `/releases/download/vMAJOR.MINOR.PATCH/Donkey.dmg`.
- The GitHub Releases page keeps no more than 10 numeric production releases,
  plus the separate nightly prerelease when present.
- `https://donkeyuse.com/appcast.xml` updates after the site deploy completes.

If Sparkle cannot validate an update, first check that the app was packaged
with the `DONKEY_SPARKLE_PUBLIC_ED_KEY` that matches the private key stored in
GitHub Actions.

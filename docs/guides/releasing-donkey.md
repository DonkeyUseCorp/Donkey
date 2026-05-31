# Releasing Donkey

Donkey production releases are distributed through GitHub Releases. The
Supabase Storage `/release` bucket is not part of the release path.

The release entrypoint is the `Release Donkey` GitHub Actions workflow. A
maintainer chooses whether to bump the major, minor, or patch version in the
GitHub UI, and the workflow builds the latest default-branch code into the
release artifact.

Nightly prereleases use a separate `Nightly Donkey Build` GitHub Actions
workflow. It builds changed default-branch code on a schedule and publishes the
result to the moving `nightly` prerelease.

## Release Boundaries

- Release tags use numeric SemVer in `vMAJOR.MINOR.PATCH` form, such as
  `v0.1.1`.
- The GitHub Release asset is `Donkey.dmg`.
- The workflow also uploads `Donkey.dmg.sha256`.
- The website download URL points to the promoted numeric release asset, not a
  moving `latest` or `-latest` URL.
- The production release workflow keeps the latest 10 numeric GitHub Releases
  and deletes older numeric release records after promotion. It does not delete
  Git tags, aliases, or the nightly prerelease.
- The public Sparkle appcast is committed at `site/public/appcast.xml` and
  served as `https://donkeyuse.com/appcast.xml`.
- Sparkle signs and validates update archives; do not add a Donkey-specific
  updater or replacement installer.

## One-Time Sparkle Setup

Generate one Sparkle EdDSA signing keypair on a trusted Mac:

```bash
apps/Donkey/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account donkey
```

Copy the printed `SUPublicEDKey` value into the GitHub repository secret:

```text
DONKEY_SPARKLE_PUBLIC_ED_KEY
```

Export the matching private key:

```bash
apps/Donkey/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account donkey \
  -x /tmp/donkey-sparkle-private-key.txt
```

Copy the file contents into this GitHub repository secret:

```text
DONKEY_SPARKLE_PRIVATE_ED_KEY
```

Delete the exported private key file after adding the secret:

```bash
rm -f /tmp/donkey-sparkle-private-key.txt
```

Keep this keypair stable. Already-installed apps trust the public key embedded
at packaging time and reject future updates signed by a different private key.

## Publishing A Release

1. Open GitHub Actions for the repository.
2. Select `Release Donkey`.
3. Click `Run workflow`.
4. Choose `patch`, `minor`, or `major`.
5. Run the workflow.

The workflow checks out the latest default branch, fetches existing numeric
release tags, derives the next version from the selected bump, builds the macOS
app, packages `dist/Donkey.dmg`, signs the DMG with the Sparkle private key,
creates or updates the numeric GitHub Release, uploads the DMG and checksum,
updates `site/public/appcast.xml`, updates the website download constant,
commits those site/appcast changes, marks the numeric release as GitHub's latest
release, and moves the alias tags. When no numeric release tag exists yet, the
workflow starts at `0.1.0`. After promotion, it deletes older production
GitHub Release records so only the latest 10 numeric releases remain.

## Alias Tags

The workflow moves these alias tags to the released commit:

- `vMAJOR`
- `vMAJOR.MINOR`
- `latest`

These aliases are for maintainer convenience. User-facing website and appcast
links must keep using the immutable numeric tag.

## Nightly Builds

The `Nightly Donkey Build` workflow runs nightly at 09:00 UTC and can also be
started manually from GitHub Actions. It compares the default-branch commit to
the current `nightly` tag before installing packaging dependencies. If the tag
already points at the default-branch commit, the workflow skips packaging and
publishing. When the default branch has changed, it packages `dist/Donkey.dmg`,
generates `dist/Donkey.dmg.sha256`, moves the `nightly` tag to that commit, and
creates or updates the `Donkey Nightly Build` prerelease.

Nightly builds are intentionally separate from production releases:

- They do not use numeric SemVer tags.
- They do not update `site/public/appcast.xml`.
- They do not update the website download version.
- They do not move production alias tags.
- They are not marked as GitHub's latest release.

Use nightly builds for smoke testing the latest default-branch app package.
Use the `Release Donkey` workflow when publishing a user-facing release.

## Verification

After the workflow finishes:

- The GitHub Release for `vMAJOR.MINOR.PATCH` contains `Donkey.dmg` and
  `Donkey.dmg.sha256`.
- The website source has `DONKEY_LATEST_VERSION` set to the numeric version.
- `site/public/appcast.xml` contains one item for that version and an enclosure
  URL under `/releases/download/vMAJOR.MINOR.PATCH/Donkey.dmg`.
- The GitHub Releases page keeps no more than 10 numeric production releases,
  plus the separate nightly prerelease when present.
- `https://donkeyuse.com/appcast.xml` updates after the site deploy completes.

If Sparkle cannot validate an update, first check that the app was packaged with
the same `DONKEY_SPARKLE_PUBLIC_ED_KEY` that matches the private key stored in
GitHub Actions.

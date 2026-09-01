# iOS builds without a local Mac

The unsigned build and unit tests run on GitHub's `macos-26` runner with Xcode 26 or newer in `ci.yml`. CI also builds a Release app for a generic iOS device, removes any signing material defensively, packages it as `InputPilot-unsigned.ipa`, and uploads it with the other CI artifacts. The separate, manually dispatched `ios-build.yml` workflow archives and exports an installable IPA using credentials that already exist; it does not create or renew Apple credentials.

## Public unsigned IPA for self-signing

The regular CI artifact has `CFBundleIdentifier=com.thorethy.inputpilot`, but no `embedded.mobileprovision`, `_CodeSignature`, Apple Team ID, certificate, or registered-device UDID list. It is therefore safe to publish but cannot be installed as-is on normal iOS. Sign it with the installer's own certificate and provisioning profile using a compatible self-signing tool. Depending on Apple account and App ID availability, that tool may need to replace `com.thorethy.inputpilot` with a bundle ID belonging to the installer's team.

Do not create the public artifact by deleting only `embedded.mobileprovision` from an already signed personal IPA. Any bundle modification invalidates the existing signature, and the signed IPA may contain identity information in both its profile and signature. Build the unsigned target from source as CI does instead.

Each tagged release also generates `altstore-source.json` from the validated
unsigned IPA. Its stable URL is
`https://github.com/thorethy1/InputPilot/releases/latest/download/altstore-source.json`.
The generator reads the bundle identifier, marketing version, build number,
privacy permissions, file size, and SHA-256 directly from the packaged IPA so
the AltStore entry cannot silently diverge from the released app.

Beta prereleases use versioned tags such as `v0.9.0-beta.1`. Their validated
AltStore source is also copied to the fixed rolling URL
`https://github.com/thorethy1/InputPilot/releases/download/beta/altstore-source.json`.
See [Stable and Beta Release Channels](RELEASE_CHANNELS.md) for branch, version,
OTA and promotion rules.

`Version.xcconfig` holds the numeric iOS marketing version and the stable or beta
firmware release identity. CI overrides `INPUTPILOT_BUILD` with its monotonically
increasing workflow run number; local builds use the harmless fallback declared
in that file.

## Repository secrets

Configure these in **Settings → Secrets and variables → Actions**:

- `IOS_CERTIFICATE_BASE64`: Base64 of the `.p12` file
- `IOS_CERTIFICATE_PASSWORD`: `.p12` password
- `IOS_PROVISIONING_PROFILE_BASE64`: Base64 of the `.mobileprovision`
- `KEYCHAIN_PASSWORD`: a random password used only for the temporary runner keychain
- optionally `APPLE_TEAM_ID` and `IOS_BUNDLE_ID`; if omitted, values are read from the profile

On Linux/Windows, use a Base64 encoder that does not add line wrapping. Never add the source files or encoded values to Git. GitHub masks configured secrets, but the workflow also avoids printing decoded profiles, private keys, passwords, and Base64 content.

## Running and downloading

Open **Actions → iOS Signed Build → Run workflow**. The job validates that a signing identity exists, checks profile expiry and bundle/team compatibility, archives the app with manual signing, and replaces `InputPilot.ipa` in an unpublished draft release. A direct download link is written to the workflow summary. The iPhone must be covered by the supplied development/ad-hoc profile.

Tags do not start this signing workflow. Its repository write permission is used only to maintain the fixed, unpublished `private-ios-signed` draft release. A personally signed development/ad-hoc IPA never becomes a public GitHub Release asset automatically. Public releases contain firmware and the separately built unsigned IPA. If secrets are absent, the signed job fails safely with their names only; regular PR CI remains usable.

All reconstructed inputs, derived data, archive, export options, and IPA staging live under `$RUNNER_TEMP`. The profile and temporary keychain are removed in an always-running cleanup step; GitHub also discards the hosted runner after the job.

Common non-sensitive diagnostics include expired profile, missing certificate identity, missing registered devices, and bundle/team mismatch. A profile that excludes the intended phone must be replaced externally in the repository secret; the workflow cannot add devices or issue Apple credentials.

## Release assets (public)

The [`create-release.yml`](/.github/workflows/create-release.yml) workflow is the stable release entry point. Choose `none` when promoting an already-versioned beta, or a semantic `patch`, `minor`, or `major` bump in **Actions → Create release**. It updates the release configuration on a temporary branch, starts CI for that exact commit, and promotes the commit to `main` only after CI succeeds. [`create-beta-release.yml`](/.github/workflows/create-beta-release.yml) applies the same exact-commit gate to versioned prereleases from `beta`. Both dispatch [`release-assets.yml`](/.github/workflows/release-assets.yml), which:

- validates the release tag against `Version.xcconfig`;
- waits for a successful CI run on the exact tag commit;
- validates, renames and uploads assets downloaded from that CI run;
- includes the **unsigned** iOS IPA from CI — identical to `InputPilot-unsigned-${{ github.sha }}` with no provisioning profile or signature. The signed IPA from the `ios-build.yml` workflow is never included in release assets, even if it exists on a previous CI run.

Published releases still trigger the asset workflow for manual/emergency use,
but the tag must match the shared version.

To repair a release that was published without assets, run the workflow manually from **Actions → Attach release assets → Run workflow** with the published tag name.

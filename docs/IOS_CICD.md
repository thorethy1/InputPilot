# Signed iOS builds without a local Mac

The unsigned build and unit tests run on GitHub's `macos-26` runner with Xcode 26 or newer in `ci.yml`. The separate, manually dispatched `ios-build.yml` workflow archives and exports an installable IPA using credentials that already exist; it does not create or renew Apple credentials.

## Repository secrets

Configure these in **Settings → Secrets and variables → Actions**:

- `IOS_CERTIFICATE_BASE64`: Base64 of the `.p12` file
- `IOS_CERTIFICATE_PASSWORD`: `.p12` password
- `IOS_PROVISIONING_PROFILE_BASE64`: Base64 of the `.mobileprovision`
- `KEYCHAIN_PASSWORD`: a random password used only for the temporary runner keychain
- optionally `APPLE_TEAM_ID` and `IOS_BUNDLE_ID`; if omitted, values are read from the profile

On Linux/Windows, use a Base64 encoder that does not add line wrapping. Never add the source files or encoded values to Git. GitHub masks configured secrets, but the workflow also avoids printing decoded profiles, private keys, passwords, and Base64 content.

## Running and downloading

Open **Actions → iOS Signed Build → Run workflow**. The job validates that a signing identity exists, checks profile expiry and bundle/team compatibility, archives the app with manual signing, and publishes `InputPilot.ipa` only in the private run's Artifacts section. The iPhone must be covered by the supplied development/ad-hoc profile.

Tags do not start this signing workflow, and the workflow has read-only repository-content permission. It contains no release creation or upload step: a personally signed development/ad-hoc IPA must never become a public GitHub Release asset automatically. Public releases may contain source, changelogs, and separately produced non-personalized artifacts. If secrets are absent, the signed job fails safely with their names only; regular PR CI remains usable.

All reconstructed inputs, derived data, archive, export options, and IPA staging live under `$RUNNER_TEMP`. The profile and temporary keychain are removed in an always-running cleanup step; GitHub also discards the hosted runner after the job.

Common non-sensitive diagnostics include expired profile, missing certificate identity, missing registered devices, and bundle/team mismatch. A profile that excludes the intended phone must be replaced externally in the repository secret; the workflow cannot add devices or issue Apple credentials.

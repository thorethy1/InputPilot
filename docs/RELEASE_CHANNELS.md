# Stable and Beta Release Channels

InputPilot uses two aligned update channels for the iOS app and ESP32-S3
firmware. Choosing a channel in the app changes firmware OTA discovery. App
updates remain managed by AltStore, so the matching AltStore source must also be
selected there.

## Channel contract

| Channel | Source branch | Tag format | GitHub release | Firmware lookup | AltStore source |
| --- | --- | --- | --- | --- | --- |
| Stable | `main` | `v0.9.0` | Normal release | GitHub `releases/latest` | `https://github.com/thorethy1/InputPilot/releases/latest/download/altstore-source.json` |
| Beta | `beta` | `v0.9.0-beta.1` | Prerelease | Newest versioned beta prerelease with OTA assets | `https://github.com/thorethy1/InputPilot/releases/download/beta/altstore-source.json` |

The fixed `beta` GitHub release is only a rolling AltStore pointer. Immutable
beta app and firmware files remain attached to their versioned prereleases.

Both channels use the same iOS bundle identifier. Do not keep both AltStore
sources active for InputPilot at the same time; remove or disable the old source
when changing channels. The app cannot silently change an external AltStore
subscription, but Settings exposes the correct source URL for sharing or adding
to AltStore.

## Version model

`Version.xcconfig` contains two related values:

- `INPUTPILOT_VERSION` is the numeric iOS marketing version, for example `0.9.0`.
- `INPUTPILOT_RELEASE` is the firmware/release identity, for example
  `0.9.0-beta.2`. Stable builds alias it to `INPUTPILOT_VERSION`.
- `INPUTPILOT_CHANNEL` makes a newly installed app default to the channel it was
  built from. An explicit user selection remains persisted across updates.

The beta AltStore entry uses the numeric IPA version/build for update detection
and shows the full prerelease identity through AltStore's `marketingVersion`.

Each beta gets a unique firmware identity. OTA ordering follows semantic-version
prerelease rules, so `0.9.0-beta.2` updates `0.9.0-beta.1`, and stable `0.9.0`
updates every `0.9.0` beta. Selecting Stable before `0.9.0` is published does
not downgrade a beta device to `0.8.x`.

## Publishing a beta

### One-time workflow bootstrap

Before the first beta release, merge the release-channel files under
`.github/workflows/` into the default `main` branch. GitHub registers manually
dispatched workflows from the default branch, and its built-in Actions token
cannot create a release for a commit that changes workflow files relative to
that branch. This bootstrap changes release infrastructure only; 0.9 product
development remains on `beta`.

1. Develop and review 0.9 changes on `beta`.
2. Push `beta` and wait for CI.
3. Run **Actions → Create beta release** from the `beta` branch.
4. Enter the next immutable version, such as `0.9.0-beta.2`.
5. The workflow updates the shared version file if needed, validates the exact
   commit in CI, advances `beta`, publishes a GitHub prerelease, attaches the
   iOS/firmware assets, and refreshes the rolling AltStore beta feed.

Never reuse a beta number or move a versioned beta tag.

## Promoting to Stable

1. Complete the 0.9 release gate on `beta`.
2. Merge `beta` into `main` through the normal reviewed path.
3. Run **Actions → Create release** on `main` with bump `none`. This changes
   `INPUTPILOT_RELEASE` from the beta identity to stable `0.9.0`, runs CI,
   publishes `v0.9.0`, and attaches stable OTA and AltStore assets.
4. Keep `beta` for the next development cycle and set its next prerelease
   identity through **Create beta release**.

Use a normal patch/minor/major bump in **Create release** only when `main` still
needs its numeric version advanced.

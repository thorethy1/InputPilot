# InputPilot Web Flasher

The static source for <https://thorethy1.github.io/InputPilot/> lives in this directory. The deployed site is built by [the Pages workflow](../../.github/workflows/pages.yml); generated firmware and manifest files are intentionally not committed.

## One-time repository setup

After this workflow is present on the default branch, open **Settings → Pages → Build and deployment** and select **GitHub Actions** as the source. Then run **Deploy web flasher** once from the Actions tab.

## Release updates

The Pages workflow runs after **Attach release assets** succeeds. It resolves GitHub's latest stable release, downloads its exact `InitialFirmware.bin`, validates the reported size and SHA-256 digest, and publishes it with an ESP Web Tools manifest on the same origin. Drafts, prereleases, missing assets, invalid tags, checksum mismatches, and images larger than the supported 4 MB flash fail the deployment instead of replacing the working site.

The workflow can also be started manually to repair or refresh the deployment.

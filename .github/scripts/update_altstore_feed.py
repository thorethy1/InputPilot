#!/usr/bin/env python3
"""Merge a freshly packaged AltStore source into the rolling channel feed."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_MAX_VERSIONS = 10


def version_key(version: dict) -> tuple[str, str]:
    """Identity of a feed entry; marketing version plus build number."""
    return (str(version.get("version", "")), str(version.get("buildVersion", "")))


def _sort_key(version: dict) -> tuple:
    """Newest-first ordering key; numeric chunks compare numerically."""

    def parts(value: str) -> tuple:
        result = []
        for chunk in str(value).replace("-", ".").split("."):
            result.append((0, int(chunk), "") if chunk.isdigit() else (1, 0, chunk))
        return tuple(result)

    return (parts(version.get("version", "")), parts(version.get("buildVersion", "")))


def merge_altstore_sources(
    new_source: dict,
    previous: dict | None,
    max_versions: int = DEFAULT_MAX_VERSIONS,
) -> dict:
    """Return a channel feed with the new release plus retained history.

    The new source is the freshly packaged single-release manifest; the
    optional previous feed is the current rolling channel manifest. Versions
    are deduplicated by (version, buildVersion) so re-running the workflow for
    the same tag refreshes its entry instead of duplicating it, while distinct
    builds of the same marketing version (beta.6 vs beta.7) are kept. App
    metadata comes from the new source so branding follows the release
    channel.
    """
    if max_versions < 1:
        raise ValueError("max_versions must be at least 1")
    apps = new_source.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("new AltStore source has no apps")
    new_app = apps[0]
    new_versions = new_app.get("versions")
    if not isinstance(new_versions, list) or not new_versions:
        raise ValueError("new AltStore source has no versions")

    merged = json.loads(json.dumps(new_source))
    merged_app = merged["apps"][0]
    bundle = str(new_app.get("bundleIdentifier", ""))

    candidates: list[dict] = [version for version in new_versions if isinstance(version, dict)]
    if isinstance(previous, dict):
        previous_apps = previous.get("apps")
        if (
            isinstance(previous_apps, list)
            and previous_apps
            and isinstance(previous_apps[0], dict)
            and str(previous_apps[0].get("bundleIdentifier", "")) == bundle
        ):
            candidates += [
                version
                for version in previous_apps[0].get("versions") or []
                if isinstance(version, dict)
            ]

    # Newest first; stable sort keeps the new release ahead of a previous
    # duplicate so workflow retries refresh an entry instead of duplicating it.
    candidates.sort(key=_sort_key, reverse=True)
    history: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for version in candidates:
        key = version_key(version)
        if key == ("", "") or key in seen:
            continue
        seen.add(key)
        history.append(version)
    if not history:
        raise ValueError("new AltStore source has no valid versions")

    merged_app["versions"] = history[:max_versions]
    return merged


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new-source", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-versions", type=int, default=DEFAULT_MAX_VERSIONS)
    args = parser.parse_args()

    new_source = json.loads(args.new_source.read_text(encoding="utf-8"))
    previous = None
    if args.previous and args.previous.is_file():
        text = args.previous.read_text(encoding="utf-8").strip()
        if text:
            try:
                previous = json.loads(text)
            except json.JSONDecodeError as error:
                print(f"warning: ignoring corrupt previous feed: {error}", file=sys.stderr)

    merged = merge_altstore_sources(new_source, previous, args.max_versions)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    versions = [version.get("version") for version in merged["apps"][0]["versions"]]
    print(f"channel feed keeps {len(versions)} versions: {versions}")


if __name__ == "__main__":
    main()

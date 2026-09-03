import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from update_altstore_feed import merge_altstore_sources

SPEC = importlib.util.spec_from_file_location(
    "update_altstore_feed_cli", Path(__file__).with_name("update_altstore_feed.py")
)


def source(version: str, build: str, date: str = "2026-09-03") -> dict:
    return {
        "name": "InputPilot Beta",
        "apps": [{
            "name": "InputPilot",
            "bundleIdentifier": "com.thorethy.inputpilot",
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": date,
                "downloadURL": f"https://example.com/{version}-{build}.ipa",
                "size": 1,
                "sha256": "0" * 64,
            }],
        }],
    }


class MergeAltStoreSourcesTests(unittest.TestCase):
    def testPrependsNewVersionAndKeepsHistory(self):
        previous = source("0.9.0", "23")
        previous["apps"][0]["versions"].append(source("0.8.20", "22")["apps"][0]["versions"][0])
        merged = merge_altstore_sources(source("0.9.0", "24"), previous)
        versions = [(v["version"], v["buildVersion"]) for v in merged["apps"][0]["versions"]]
        self.assertEqual(versions, [("0.9.0", "24"), ("0.9.0", "23"), ("0.8.20", "22")])

    def testRerunForSameTagRefreshesEntryInsteadOfDuplicating(self):
        previous = source("0.9.0", "24", date="2026-09-02")
        merged = merge_altstore_sources(source("0.9.0", "24", date="2026-09-03"), previous)
        versions = merged["apps"][0]["versions"]
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["date"], "2026-09-03")

    def testDistinctBuildsOfSameMarketingVersionAreKept(self):
        previous = source("0.9.0", "24")
        merged = merge_altstore_sources(source("0.9.0", "25"), previous)
        versions = [(v["version"], v["buildVersion"]) for v in merged["apps"][0]["versions"]]
        self.assertEqual(versions, [("0.9.0", "25"), ("0.9.0", "24")])

    def testHistoryIsCappedAndNewestFirst(self):
        previous = source("0.9.0", "1")
        for build in range(2, 15):
            previous["apps"][0]["versions"].append(source("0.9.0", str(build))["apps"][0]["versions"][0])
        merged = merge_altstore_sources(source("0.9.0", "15"), previous, max_versions=10)
        builds = [v["buildVersion"] for v in merged["apps"][0]["versions"]]
        self.assertEqual(builds, [str(build) for build in range(15, 5, -1)])

    def testPreviousFromDifferentBundleIsIgnored(self):
        previous = source("0.8.20", "22")
        previous["apps"][0]["bundleIdentifier"] = "com.other.app"
        merged = merge_altstore_sources(source("0.9.0", "24"), previous)
        versions = [v["buildVersion"] for v in merged["apps"][0]["versions"]]
        self.assertEqual(versions, ["24"])

    def testCorruptOrMissingPreviousIsTolerated(self):
        for previous in (None, {}, {"apps": []}, {"apps": [{"versions": "bad"}]}):
            merged = merge_altstore_sources(source("0.9.0", "24"), previous)
            self.assertEqual(len(merged["apps"][0]["versions"]), 1)

    def testInvalidNewSourceIsRejected(self):
        for new_source in ({}, {"apps": []}, source("0.9.0", "24") | {"apps": [{"versions": []}]}):
            with self.assertRaises(ValueError):
                merge_altstore_sources(new_source, None)

    def testMetadataComesFromNewSource(self):
        previous = source("0.8.20", "22")
        previous["name"] = "Old Branding"
        merged = merge_altstore_sources(source("0.9.0", "24"), previous)
        self.assertEqual(merged["name"], "InputPilot Beta")
        self.assertNotIn("Old Branding", json.dumps(merged))


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, args):
        import subprocess
        import sys

        script = Path(__file__).with_name("update_altstore_feed.py")
        return subprocess.run(
            [sys.executable, str(script), *args],
            capture_output=True,
            text=True,
            check=True,
        )

    def testCliMergesPreviousFeedFile(self):
        new_source = self.root / "new.json"
        previous = self.root / "previous.json"
        output = self.root / "merged.json"
        new_source.write_text(json.dumps(source("0.9.0", "25")), encoding="utf-8")
        previous.write_text(json.dumps(source("0.9.0", "24")), encoding="utf-8")

        self.run_cli([
            "--new-source", str(new_source),
            "--previous", str(previous),
            "--output", str(output),
        ])

        merged = json.loads(output.read_text(encoding="utf-8"))
        versions = [v["buildVersion"] for v in merged["apps"][0]["versions"]]
        self.assertEqual(versions, ["25", "24"])

    def testCliToleratesCorruptPreviousFeed(self):
        new_source = self.root / "new.json"
        previous = self.root / "previous.json"
        output = self.root / "merged.json"
        new_source.write_text(json.dumps(source("0.9.0", "25")), encoding="utf-8")
        previous.write_text("not json at all", encoding="utf-8")

        result = self.run_cli([
            "--new-source", str(new_source),
            "--previous", str(previous),
            "--output", str(output),
        ])

        self.assertIn("corrupt previous feed", result.stderr)
        merged = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(len(merged["apps"][0]["versions"]), 1)


if __name__ == "__main__":
    unittest.main()

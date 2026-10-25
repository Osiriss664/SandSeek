#!/usr/bin/env python3
"""Tests for Scripts/make_sbom.py. They need no network and no Mac.

  python3 -m unittest Scripts/test_make_sbom.py

Most run against the real Sandbox/ files of this checkout; the failure cases
use a temporary fake checkout (--repo-root).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "make_sbom.py")
CREATED = "2026-10-22T00:00:00Z"


def run(output, *extra, root=None, env=None):
    command = [sys.executable, SCRIPT, "--version", "0.5.0", "--output", output, "--created", CREATED]
    if root:
        command += ["--repo-root", root]
    command += list(extra)
    environment = dict(os.environ)
    environment.pop("SOURCE_DATE_EPOCH", None)
    environment.update(env or {})
    return subprocess.run(command, capture_output=True, text=True, env=environment)


class Temp(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="sbom-")
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def path(self, *parts):
        return os.path.join(self.directory, *parts)

    def fake_checkout(self, requirements=None, containerfile=None):
        root = self.path("repo")
        os.makedirs(os.path.join(root, "Sandbox"))
        shutil.copy(os.path.join(ROOT, "Sandbox", "Containerfile"), os.path.join(root, "Sandbox", "Containerfile"))
        with open(os.path.join(root, "Sandbox", "requirements.txt"), "w") as handle:
            handle.write(requirements if requirements is not None else "six==1.17.0 \\\n    --hash=sha256:" + "a" * 64 + "\n")
        if containerfile is not None:
            with open(os.path.join(root, "Sandbox", "Containerfile"), "w") as handle:
                handle.write(containerfile)
        return root


class RealRepoTests(Temp):
    def generate(self, *extra):
        output = self.path("sbom.json")
        result = run(output, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(output, encoding="utf-8") as handle:
            return json.load(handle)

    def test_required_spdx_fields(self):
        document = self.generate("--source-commit", "abcdef1234567")
        for field in ("spdxVersion", "dataLicense", "SPDXID", "name", "documentNamespace", "creationInfo", "packages", "relationships"):
            self.assertIn(field, document)
        self.assertEqual(document["spdxVersion"], "SPDX-2.3")
        self.assertEqual(document["dataLicense"], "CC0-1.0")
        self.assertEqual(document["creationInfo"]["created"], CREATED)
        self.assertTrue(document["creationInfo"]["creators"])
        self.assertEqual(
            document["documentNamespace"], "https://github.com/Osiriss664/SandSeek/spdx/0.5.0-abcdef1234567"
        )
        ids = [package["SPDXID"] for package in document["packages"]]
        self.assertEqual(len(ids), len(set(ids)))
        for package in document["packages"]:
            for field in ("SPDXID", "name", "downloadLocation", "filesAnalyzed", "licenseConcluded", "licenseDeclared", "copyrightText"):
                self.assertIn(field, package, package["name"])
            self.assertTrue(re.match(r"^SPDXRef-[A-Za-z0-9.-]+$", package["SPDXID"]), package["SPDXID"])
        known = set(ids) | {"SPDXRef-DOCUMENT"}
        for relationship in document["relationships"]:
            self.assertIn(relationship["spdxElementId"], known)
            self.assertIn(relationship["relatedSpdxElement"], known)

    def test_namespace_without_commit_is_local(self):
        self.assertTrue(self.generate()["documentNamespace"].endswith("/spdx/0.5.0-local"))

    def test_root_package_and_relationships(self):
        document = self.generate()
        by_id = {package["SPDXID"]: package for package in document["packages"]}
        root = by_id["SPDXRef-SandSeek"]
        self.assertEqual(root["versionInfo"], "0.5.0")
        self.assertEqual(root["licenseDeclared"], "Apache-2.0")
        self.assertEqual(root["downloadLocation"], "https://github.com/Osiriss664/SandSeek")
        self.assertEqual(root["supplier"], "Person: Osiriss664")
        self.assertEqual(root["externalRefs"][0]["referenceLocator"], "pkg:github/Osiriss664/SandSeek@v0.5.0")
        triples = {(r["spdxElementId"], r["relationshipType"], r["relatedSpdxElement"]) for r in document["relationships"]}
        self.assertIn(("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-SandSeek"), triples)
        self.assertIn(("SPDXRef-SandSeek", "CONTAINS", "SPDXRef-SandboxImage"), triples)
        for package in document["packages"]:
            if package["SPDXID"] not in ("SPDXRef-SandSeek", "SPDXRef-SandboxImage"):
                self.assertIn(("SPDXRef-SandboxImage", "CONTAINS", package["SPDXID"]), triples)

    def test_every_requirement_is_listed_with_its_version(self):
        with open(os.path.join(ROOT, "Sandbox", "requirements.txt"), encoding="utf-8") as handle:
            text = handle.read()
        expected = re.findall(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", text, re.MULTILINE)
        self.assertGreater(len(expected), 10)
        document = self.generate()
        listed = {(p["name"], p.get("versionInfo")): p for p in document["packages"]}
        for name, version in expected:
            self.assertIn((name, version), listed)
            package = listed[(name, version)]
            self.assertEqual(package["externalRefs"][0]["referenceLocator"], f"pkg:pypi/{name.lower()}@{version}")
            self.assertEqual(package["downloadLocation"], "NOASSERTION")
            self.assertTrue(package["checksums"])
        # All hashes of one package are kept.
        block = re.search(r"^pypdf==\S+ \\\n((?:\s+--hash=\S+(?: \\)?\n)+)", text, re.MULTILINE).group(1)
        hashes = re.findall(r"sha256:([0-9a-f]{64})", block)
        pypdf = next(p for p in document["packages"] if p["name"] == "pypdf")
        self.assertEqual(sorted(h["checksumValue"] for h in pypdf["checksums"]), sorted(hashes))

    def test_base_image_digest_matches_containerfile(self):
        with open(os.path.join(ROOT, "Sandbox", "Containerfile"), encoding="utf-8") as handle:
            line = next(l for l in handle if l.startswith("FROM "))
        digest = re.search(r"@sha256:([0-9a-f]{64})", line).group(1)
        document = self.generate()
        base = next(p for p in document["packages"] if p["SPDXID"] == "SPDXRef-BaseImage")
        self.assertEqual(base["name"], "docker.io/library/python")
        self.assertEqual(base["versionInfo"], "3.12-slim")
        self.assertEqual(base["checksums"], [{"algorithm": "SHA256", "checksumValue": digest}])
        self.assertEqual(
            base["externalRefs"][0]["referenceLocator"],
            f"pkg:docker/library/python@sha256:{digest}?repository_url=docker.io&tag=3.12-slim",
        )

    def test_debian_packages_carry_the_snapshot_date(self):
        with open(os.path.join(ROOT, "Sandbox", "Containerfile"), encoding="utf-8") as handle:
            text = handle.read()
        snapshot = re.search(r"^ARG DEBIAN_SNAPSHOT=(\S+)", text, re.MULTILINE).group(1)
        document = self.generate()
        nftables = next(p for p in document["packages"] if p["name"] == "nftables")
        self.assertEqual(nftables["versionInfo"], f"from snapshot {snapshot}")

    def test_output_is_deterministic(self):
        first, second = self.path("a.json"), self.path("b.json")
        self.assertEqual(run(first, "--source-commit", "abcdef1").returncode, 0)
        self.assertEqual(run(second, "--source-commit", "abcdef1").returncode, 0)
        with open(first, "rb") as a, open(second, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_created_defaults_to_source_date_epoch(self):
        output = self.path("epoch.json")
        command = [sys.executable, SCRIPT, "--version", "0.5.0", "--output", output]
        env = dict(os.environ, SOURCE_DATE_EPOCH="1760000000")
        self.assertEqual(subprocess.run(command, capture_output=True, text=True, env=env).returncode, 0)
        with open(output) as handle:
            self.assertEqual(json.load(handle)["creationInfo"]["created"], "2025-10-09T08:53:20Z")


class FailureTests(Temp):
    def expect_failure(self, root, message, *extra):
        output = self.path("out.json")
        result = run(output, *extra, root=root)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse(os.path.exists(output))

    def test_fake_checkout_works(self):
        root = self.fake_checkout()
        result = run(self.path("out.json"), root=root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unpinned_requirement_fails(self):
        root = self.fake_checkout("six>=1.17.0 \\\n    --hash=sha256:" + "a" * 64 + "\n")
        self.expect_failure(root, "not an exact pin")

    def test_requirement_with_extras_is_listed_by_name(self):
        root = self.fake_checkout("lxml[html-clean]==6.1.3 \\\n    --hash=sha256:" + "a" * 64 + "\n")
        output = self.path("out.json")
        result = run(output, root=root)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(output, encoding="utf-8") as handle:
            packages = json.load(handle)["packages"]
        found = [(item["name"], item.get("versionInfo")) for item in packages if item["name"].startswith("lxml")]
        self.assertEqual(found, [("lxml", "6.1.3")])

    def test_requirement_without_hash_fails(self):
        root = self.fake_checkout("six==1.17.0\n")
        self.expect_failure(root, "no --hash=sha256")

    def test_missing_digest_fails(self):
        with open(os.path.join(ROOT, "Sandbox", "Containerfile"), encoding="utf-8") as handle:
            text = re.sub(r"@sha256:[0-9a-f]{64}", "", handle.read())
        root = self.fake_checkout(containerfile=text)
        self.expect_failure(root, "no @sha256 digest")

    def test_package_resolved_with_pins_fails(self):
        root = self.fake_checkout()
        with open(os.path.join(root, "Package.resolved"), "w") as handle:
            json.dump({"pins": [{"identity": "x"}], "version": 3}, handle)
        self.expect_failure(root, "Swift dependencies")

    def test_empty_package_resolved_is_fine(self):
        root = self.fake_checkout()
        with open(os.path.join(root, "Package.resolved"), "w") as handle:
            json.dump({"pins": [], "version": 3}, handle)
        self.assertEqual(run(self.path("out.json"), root=root).returncode, 0)

    def test_bad_version_fails(self):
        output = self.path("out.json")
        command = [sys.executable, SCRIPT, "--version", "v0.5", "--output", output]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("must look like", result.stderr)


if __name__ == "__main__":
    unittest.main()

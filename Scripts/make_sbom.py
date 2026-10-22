#!/usr/bin/env python3
"""Writes an SPDX 2.3 JSON software bill of materials (SBOM) for a SandSeek release.

  python3 Scripts/make_sbom.py --version 0.5.0 --output sandseek-0.5.0.spdx.json \
      [--source-commit SHA] [--created 2026-10-22T00:00:00Z] [--repo-root DIR]

It reads only files in the checkout and uses only the standard library: no
network, no third-party module, so the release workflow can run it before it
trusts anything it downloaded. What it lists:

- the root package, SandSeek itself;
- the sandbox image as one package that the root contains, and inside it
  - the base image from the FROM line of Sandbox/Containerfile (name, tag and
    sha256 digest),
  - the Debian packages the Containerfile installs with apt-get, with the
    snapshot date they come from (DEBIAN_SNAPSHOT); the exact version is
    decided by that snapshot and is not known here, so it is NOASSERTION,
  - every Python package pinned in Sandbox/requirements.txt, with its hashes.

The Swift package has no dependencies. If a Package.resolved with pins ever
appears, this script refuses to run instead of writing an SBOM that silently
misses them: extend it first.

The output is deterministic: sorted, with stable SPDX identifiers, and the
creation time comes from --created, then SOURCE_DATE_EPOCH, then the clock.
Any input it cannot read with certainty is an error (exit 1), never a guess.
"""

import argparse
import datetime
import json
import os
import re
import sys

REPO_URL = "https://github.com/Osiriss664/SandSeek"
SUPPLIER = "Person: Osiriss664"
SPDX_VERSION = "SPDX-2.3"

VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CREATED_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{7,64}$")
FROM_PATTERN = re.compile(
    r"^FROM\s+(?P<name>[^\s:@]+)(?::(?P<tag>[^\s@]+))?(?:@sha256:(?P<digest>[^\s]+))?\s*$"
)
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SNAPSHOT_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
HASH_PATTERN = re.compile(r"^--hash=sha256:([0-9a-f]{64})$")
REQUIREMENT_PATTERN = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9][A-Za-z0-9._+!-]*)$")
PACKAGE_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.+-]*$")


class SbomError(Exception):
    """An input is missing or not what this script can read with certainty."""


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as error:
        raise SbomError(f"Cannot read {path}: {error.strerror or error}") from error


def logical_lines(text):
    """The file's lines with backslash continuations joined and comments removed."""
    lines = []
    pending = ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        line = pending + line
        pending = ""
        lines.append(line)
    if pending:
        lines.append(pending)
    return lines


def check_swift_dependencies(root):
    """The Swift package must have no dependencies; fail if a lock file says otherwise."""
    for relative in ("Package.resolved", ".swiftpm/Package.resolved"):
        path = os.path.join(root, relative)
        if not os.path.exists(path):
            continue
        try:
            data = json.loads(read_text(path))
        except ValueError as error:
            raise SbomError(f"{relative} is not valid JSON ({error}); cannot tell if Swift dependencies exist.") from error
        pins = data.get("pins")
        if pins is None and isinstance(data.get("object"), dict):
            pins = data["object"].get("pins")  # version 1 of the format
        if pins is None or pins:
            raise SbomError(
                f"{relative} lists Swift dependencies (or has an unknown format). "
                "make_sbom.py does not list Swift dependencies yet; add them before releasing."
            )


def parse_containerfile(root):
    """Returns (base image fields, snapshot date, apt package names)."""
    path = os.path.join(root, "Sandbox", "Containerfile")
    lines = logical_lines(read_text(path))

    base = None
    snapshot = None
    apt_packages = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        if stripped.upper().startswith("FROM ") and base is None:
            match = FROM_PATTERN.match(stripped)
            if not match:
                raise SbomError(f"Sandbox/Containerfile: cannot read the FROM line: {stripped}")
            base = match.groupdict()
        match = re.match(r"^ARG\s+DEBIAN_SNAPSHOT=(\S+)$", stripped)
        if match:
            snapshot = match.group(1)
        if "apt-get install" in stripped:
            # The RUN line is one logical line of commands joined by ; and &&.
            for command in re.split(r";|&&", stripped):
                command = command.strip()
                if "apt-get install" not in command:
                    continue
                words = command.split("apt-get install", 1)[1].split()
                apt_packages += [word for word in words if not word.startswith("-")]

    if base is None:
        raise SbomError("Sandbox/Containerfile has no FROM line.")
    if not base["digest"]:
        raise SbomError("Sandbox/Containerfile: the FROM line has no @sha256 digest; the base image must be pinned.")
    if not DIGEST_PATTERN.match(base["digest"]):
        raise SbomError(f"Sandbox/Containerfile: the base image digest is not 64 hex digits: {base['digest']}")
    if not base["tag"]:
        raise SbomError("Sandbox/Containerfile: the FROM line has no tag.")
    if snapshot is None:
        raise SbomError("Sandbox/Containerfile has no 'ARG DEBIAN_SNAPSHOT=' line.")
    if not SNAPSHOT_PATTERN.match(snapshot):
        raise SbomError(f"Sandbox/Containerfile: DEBIAN_SNAPSHOT is not like 20261002T000000Z: {snapshot}")
    if not apt_packages:
        raise SbomError("Sandbox/Containerfile: found no packages after 'apt-get install'.")
    for name in apt_packages:
        if not PACKAGE_NAME_PATTERN.match(name):
            raise SbomError(f"Sandbox/Containerfile: cannot read the apt package name: {name!r}")
    return base, snapshot, sorted(set(apt_packages))


def parse_requirements(root):
    """Returns a list of (name, version, [sha256, ...]) for Sandbox/requirements.txt."""
    path = os.path.join(root, "Sandbox", "requirements.txt")
    packages = []
    for line in logical_lines(read_text(path)):
        # Comments ("# via ...") may follow on the same logical line only after the
        # hashes; a whole-line comment is skipped.
        line = re.sub(r"(^|\s)#.*$", "", line).strip()
        if not line:
            continue
        words = line.split()
        requirement = words[0]
        match = REQUIREMENT_PATTERN.match(requirement)
        if not match:
            raise SbomError(f"Sandbox/requirements.txt: not an exact pin (name==version): {requirement}")
        hashes = []
        for word in words[1:]:
            hash_match = HASH_PATTERN.match(word)
            if not hash_match:
                raise SbomError(f"Sandbox/requirements.txt: unexpected text after {requirement}: {word}")
            hashes.append(hash_match.group(1))
        if not hashes:
            raise SbomError(f"Sandbox/requirements.txt: {requirement} has no --hash=sha256 value.")
        packages.append((match.group(1), match.group(2), sorted(set(hashes))))
    if not packages:
        raise SbomError("Sandbox/requirements.txt pins no packages.")
    names = [name.lower().replace("_", "-").replace(".", "-") for name, _, _ in packages]
    if len(set(names)) != len(names):
        raise SbomError("Sandbox/requirements.txt pins a package twice.")
    return sorted(packages, key=lambda item: item[0].lower())


def spdx_id(prefix, name):
    return "SPDXRef-" + prefix + "-" + re.sub(r"[^A-Za-z0-9.-]", "-", name)


def package(spdx, name, version, **extra):
    entry = {
        "SPDXID": spdx,
        "name": name,
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
    }
    if version is not None:
        entry["versionInfo"] = version
    entry.update(extra)
    return entry


def purl_ref(locator):
    return {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": locator}


def build_document(root, version, source_commit, created):
    check_swift_dependencies(root)
    base, snapshot, apt_packages = parse_containerfile(root)
    requirements = parse_requirements(root)

    root_id = "SPDXRef-SandSeek"
    image_id = "SPDXRef-SandboxImage"
    base_id = "SPDXRef-BaseImage"

    packages = [
        package(
            root_id,
            "SandSeek",
            version,
            downloadLocation=REPO_URL,
            supplier=SUPPLIER,
            licenseConcluded="Apache-2.0",
            licenseDeclared="Apache-2.0",
            externalRefs=[purl_ref(f"pkg:github/Osiriss664/SandSeek@v{version}")],
        ),
        # One package for what runs in the sandbox VM, so the root's direct
        # contents (the Swift code) and the image's contents stay apart.
        package(
            image_id,
            "SandSeek sandbox image",
            version,
            supplier=SUPPLIER,
            comment=(
                "Built from Sandbox/Containerfile by Scripts/research_sandbox.sh. "
                "Everything in it is pinned: base image by digest, Debian packages by "
                f"snapshot date ({snapshot}), Python packages by hash."
            ),
        ),
    ]
    relationships = [
        {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root_id},
        {"spdxElementId": root_id, "relationshipType": "CONTAINS", "relatedSpdxElement": image_id},
    ]

    image_name = base["name"]
    # docker.io/library/python -> registry docker.io, purl namespace library, name python.
    parts = image_name.split("/")
    registry = parts[0] if "." in parts[0] or ":" in parts[0] else "docker.io"
    path_parts = parts[1:] if registry == parts[0] and len(parts) > 1 else parts
    if len(path_parts) == 1:
        path_parts = ["library"] + path_parts
    purl = (
        "pkg:docker/" + "/".join(path_parts) + "@sha256:" + base["digest"]
        + f"?repository_url={registry}&tag={base['tag']}"
    )
    packages.append(
        package(
            base_id,
            image_name,
            base["tag"],
            checksums=[{"algorithm": "SHA256", "checksumValue": base["digest"]}],
            externalRefs=[purl_ref(purl)],
            comment=f"Base image {image_name}:{base['tag']}@sha256:{base['digest']} (FROM line of Sandbox/Containerfile).",
        )
    )
    relationships.append({"spdxElementId": image_id, "relationshipType": "CONTAINS", "relatedSpdxElement": base_id})

    for name in apt_packages:
        spdx = spdx_id("Deb", name)
        packages.append(
            package(
                spdx,
                name,
                f"from snapshot {snapshot}",
                supplier="Organization: Debian",
                comment=(
                    "Installed with apt-get from snapshot.debian.org at the date in versionInfo "
                    "(ARG DEBIAN_SNAPSHOT). The exact version is decided by that snapshot and "
                    "is not recorded here."
                ),
            )
        )
        relationships.append({"spdxElementId": image_id, "relationshipType": "CONTAINS", "relatedSpdxElement": spdx})

    for name, pinned, hashes in requirements:
        spdx = spdx_id("Python", name)
        normalized = name.lower().replace("_", "-").replace(".", "-")
        packages.append(
            package(
                spdx,
                name,
                pinned,
                checksums=[{"algorithm": "SHA256", "checksumValue": value} for value in hashes],
                externalRefs=[purl_ref(f"pkg:pypi/{normalized}@{pinned}")],
            )
        )
        relationships.append({"spdxElementId": image_id, "relationshipType": "CONTAINS", "relatedSpdxElement": spdx})

    packages.sort(key=lambda item: item["SPDXID"])
    relationships.sort(key=lambda item: (item["relationshipType"], item["spdxElementId"], item["relatedSpdxElement"]))

    return {
        "spdxVersion": SPDX_VERSION,
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"SandSeek {version}",
        "documentNamespace": f"{REPO_URL}/spdx/{version}-{source_commit or 'local'}",
        "creationInfo": {
            "created": created,
            "creators": ["Tool: SandSeek-Scripts/make_sbom.py"],
        },
        "packages": packages,
        "relationships": relationships,
    }


def default_created():
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        try:
            moment = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
        except (ValueError, OverflowError, OSError) as error:
            raise SbomError(f"SOURCE_DATE_EPOCH is not a Unix time: {epoch}") from error
    else:
        moment = datetime.datetime.now(datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Write an SPDX 2.3 JSON SBOM for a SandSeek release.")
    parser.add_argument("--version", required=True, help="release version, like 0.5.0")
    parser.add_argument("--output", required=True, help="file to write")
    parser.add_argument("--source-commit", help="git commit the release is built from")
    parser.add_argument("--created", help="creation time, like 2026-10-22T00:00:00Z (default: SOURCE_DATE_EPOCH, else now)")
    parser.add_argument("--repo-root", default=os.path.dirname(here), help="checkout to read (default: this one)")
    args = parser.parse_args(argv)

    try:
        if not VERSION_PATTERN.match(args.version):
            raise SbomError(f"The version must look like 1.2.3, not: {args.version}")
        if args.source_commit is not None and not COMMIT_PATTERN.match(args.source_commit):
            raise SbomError(f"The source commit must be 7 to 64 hex digits, not: {args.source_commit}")
        created = args.created or default_created()
        if not CREATED_PATTERN.match(created):
            raise SbomError(f"--created must look like 2026-10-22T00:00:00Z, not: {created}")
        document = build_document(args.repo_root, args.version, args.source_commit, created)
        text = json.dumps(document, indent=2, sort_keys=True) + "\n"
        try:
            with open(args.output, "w", encoding="utf-8") as handle:
                handle.write(text)
        except OSError as error:
            raise SbomError(f"Cannot write {args.output}: {error.strerror or error}") from error
    except SbomError as error:
        print(f"make_sbom.py: {error}", file=sys.stderr)
        return 1
    print(f"Wrote {args.output} ({len(document['packages'])} packages).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

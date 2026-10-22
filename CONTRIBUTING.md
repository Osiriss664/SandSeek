# Contributing to SandSeek

Thanks for wanting to help. SandSeek is small and young; ideas, bug reports
and careful changes are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first, so we can agree
  on the approach before you spend time on it.
- Security problems: see [SECURITY.md](SECURITY.md), never a public issue.

## Setting up

You need an Apple silicon Mac with macOS 26 or newer, Apple `container` (1.5.0 or
newer, at `/usr/local/bin/container`) and a Swift 6.2 toolchain. [docs/INSTALL.md](docs/INSTALL.md) has the details.

```
swift build
swift test
python3 -m unittest Sandbox/test_server.py
python3 -m unittest discover -s Scripts -p 'test_*.py'
Scripts/full_test.sh
```

`Scripts/full_test.sh` runs every check that needs no clicks. For a change to
the sandbox, add `--safety`.

The sandbox tests run without the VM. Tests that need a real sandbox or a
model server are described in [docs/SECURITY.md](docs/SECURITY.md).

## Changes

- Keep a change focused on one thing, with tests for what it fixes or adds.
- Anything that changes what the model, the sandbox or a web page can reach
  needs a note in docs/SECURITY.md.
- Write commit messages that say what changed and why.
- Documentation is in English.

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`), not on
a Mac, so that the files come with checksums, provenance and an SBOM. A
person still decides when a release goes out.

1. Bump `Sources/SandSeekCore/SandSeekVersion.swift` and add the version to
   `CHANGELOG.md`. The entry needs a `### Security` subsection: the advisories
   fixed, with credit to whoever reported them, or "No security fixes in this
   release." The workflow refuses a tag without it.
2. Merge, and test the merged code on a Mac (`Scripts/full_test.sh`).
3. Push the tag `vX.Y.Z` (the version must match `SandSeekVersion.swift`).
4. The workflow runs the tests and builds a **draft** release with the app zip,
   the command line tarball, the SBOM (`Scripts/make_sbom.py`), `SHA256SUMS`
   and the provenance and SBOM attestations. It never publishes and never
   overwrites an existing release.
5. Download the draft's files into one folder and verify them:
   `shasum -a 256 -c SHA256SUMS` and
   `gh attestation verify SandSeek-X.Y.Z.zip --repo Osiriss664/SandSeek`.
6. Test that exact zip on a Mac (it is signed ad hoc, so use Open Anyway), then
   publish the draft.

By contributing you agree that your work is licensed under the Apache License
2.0, like the rest of the project.

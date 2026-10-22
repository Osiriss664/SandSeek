# Security policy

SandSeek lets a local model read the web, so security problems matter. Thank
you for reporting them responsibly.

## Security maintainer

Security reports are handled by **Alex ([@Osiriss664](https://github.com/Osiriss664))**,
the owner and security maintainer of SandSeek. Alex reads every private
report, decides on the fix, publishes the advisory and requests the CVE when
one is needed.

## How to report

Please **do not open a public issue**. Use GitHub's private reporting instead:
open the **Security** tab of this repository and choose **Report a
vulnerability**
([direct link](https://github.com/Osiriss664/SandSeek/security/advisories/new)).
Only the maintainer sees the report.

Helpful to include:

- what an attacker could do (for example: a web page or PDF makes SandSeek
  reach your Mac, read a file, or send data somewhere),
- the steps or a sample page or file that shows it,
- the versions: `sandseek --version`, macOS, `container --version`, model
  server and model.

## Response times

SandSeek is maintained by one person in their spare time. These are the
times we aim for, counted from your report:

| Step | Target |
| --- | --- |
| First answer (we have it and are looking) | 7 days |
| Assessment (is it a vulnerability, how severe) | 14 days |
| Fix released for a high or critical issue | 30 days |
| Fix released for a medium or low issue | 90 days |

If a fix needs more time, we say so in the report, with the reason and a new
date. If you have not heard back after 7 days, add a comment to the report.

## Disclosure process

1. You report privately (above). We confirm and agree on the severity with
   you, in the report.
2. We fix it in the temporary private fork GitHub makes for the advisory,
   test it on a Mac, and agree on a release date with you.
3. We release the fix, publish the GitHub Security Advisory (with a CVE when
   the issue is a real vulnerability in SandSeek) and name it in the
   **Security** section of [CHANGELOG.md](CHANGELOG.md).
4. You are free to publish your own write-up once the advisory is public, or
   after 90 days from your report, whichever comes first, unless we agree on
   another date together.

**Problems in other projects.** If the problem is in a model server, a
library or another tool that SandSeek uses (for example a model server's
own HTTP API), please report it to that project too. We do not name such a
problem in this repository, its issues or its changelog before that project
has had the chance to fix it, and we can help coordinate if you like.

## Credit

We credit every reporter of a confirmed vulnerability by name or handle in
the advisory and in the changelog, unless you ask to stay anonymous. Tell us
in the report how you want to be named. There is no bug bounty.

## Good-faith research

Research on your own Mac, with your own model server and your own test pages,
is welcome. Please do not test against other people's machines or services,
and do not access data that is not yours. We will not take action against
research that follows this policy.

## Supported versions

Only the latest release gets security fixes.

| Version | Supported |
| --- | --- |
| 0.4.x | yes |
| 0.3.x | no |
| 0.2.x | no |
| 0.1.x | no |

## What counts

The design and its limits are in [docs/SECURITY.md](docs/SECURITY.md). A model
that follows instructions hidden in a web page is a known limit, not a
vulnerability, as long as it can only do what the model is allowed to do
(search and read pages). Anything that gets past the sandbox, the address
checks, the signed answers or the report cleaning is a vulnerability.

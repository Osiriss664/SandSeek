# Security policy

SandSeek lets a local model read the web, so security problems matter. Thank
you for reporting them responsibly.

## How to report

Please **do not open a public issue**. Use GitHub's private reporting instead:
open the **Security** tab of this repository and choose **Report a
vulnerability**. Only the maintainer sees the report.

Helpful to include:

- what an attacker could do (for example: a web page or PDF makes SandSeek
  reach your Mac, read a file, or send data somewhere),
- the steps or a sample page or file that shows it,
- the versions: `sandseek --version`, macOS, `container --version`, model
  server and model.

You get an answer as soon as possible; this is a spare-time project without
fixed response times.

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

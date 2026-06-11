# Security Policy

## Supported Versions

SnoutDB is currently pre-`v1.0.0`. Security fixes are applied to the latest
code on `main` and the latest published `v0.x` release when practical.

| Version | Supported |
|---|---|
| Latest `v0.x` | Yes |
| Older snapshots | Best effort |

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting feature from the repository's
**Security** tab. Repository maintainers should enable this feature before the
project is announced publicly.

Include:

- affected version or commit;
- operating system and architecture;
- reproduction steps or a minimal proof of concept;
- expected impact;
- suggested mitigation, if known.

Avoid accessing data you do not own, disrupting systems, or publishing details
before maintainers have had a reasonable opportunity to investigate.

## Response

Maintainers will aim to:

- acknowledge a report within 7 days;
- confirm whether it can be reproduced;
- communicate severity and remediation plans;
- credit the reporter if requested and appropriate;
- publish a fix and advisory when the impact warrants it.

These are targets, not service-level guarantees.

## Security-Relevant Areas

Reports are especially useful for malformed input handling, integer overflow,
memory safety, `.snout` validation, path handling, C ABI ownership, and denial
of service through excessive resource consumption.

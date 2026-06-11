# Repository Guide

This document describes the recommended GitHub configuration and maintenance
workflow for SnoutDB.

## Default Branch

Use `main` as the default branch. Treat it as releasable:

- changes arrive through pull requests;
- required CI checks must pass;
- force pushes and branch deletion are disabled;
- compatibility changes receive explicit review;
- direct commits are reserved for repository recovery or similarly exceptional
  maintenance.

For a solo-maintained repository, requiring a pull request is still useful, but
requiring an external approval may be impractical. Add an approval requirement
when additional maintainers are available.

## Merge Strategy

Use **squash merge** by default. The final commit should follow the Conventional
Commit style documented in [CONTRIBUTING.md](../CONTRIBUTING.md).

Recommended repository settings:

- enable squash merging;
- disable merge commits;
- optionally enable rebase merging for carefully curated histories;
- automatically delete head branches after merge;
- require conversations to be resolved before merge;
- require the `test` CI job to pass.

## Pull Request Review

Review in this order:

1. Correctness and data integrity.
2. Memory ownership and error paths.
3. Compatibility impact.
4. Test coverage.
5. Maintainability.
6. Performance evidence.
7. Documentation.

Changes to storage, ingestion, query execution, merge, or the C ABI should
receive additional scrutiny because they affect persisted data, large inputs,
or external integrations.

## Labels

Recommended labels:

| Label | Purpose |
|---|---|
| `bug` | Confirmed incorrect behavior |
| `enhancement` | New capability or improvement |
| `documentation` | Documentation-only work |
| `performance` | Benchmarks or hot-path work |
| `storage` | `.snout` format and persistence |
| `ingestion` | CSV, JSONL, and log input |
| `query` | Filtering, grouping, sorting, aggregates |
| `c-api` | C ABI and language bindings |
| `breaking-change` | Compatibility impact before v1.0 |
| `good first issue` | Focused task with clear acceptance criteria |
| `help wanted` | Maintainers are actively seeking contributions |

## Discussions and Support

Enable GitHub Discussions for usage questions and design conversations. Keep
bug reports and actionable feature requests in Issues so they can be tracked
and closed by pull requests.

## Security

Enable **Private vulnerability reporting** in the repository Security settings
before public announcement. Follow [SECURITY.md](../SECURITY.md) for handling
reports.

## Releases

Releases are driven by the canonical `VERSION` file. A normal merge to `main`
does not publish anything while the matching tag already exists. To prepare a
new release:

1. Update `VERSION`.
2. Update `CHANGELOG.md`.
3. Confirm README and architecture documentation.
4. Run `./scripts/validate-release.sh`.
5. Merge the release preparation PR.
6. The release workflow validates the merged commit and creates the annotated
   `v<version>` tag when it does not already exist.
7. The workflow generates release notes from merged pull requests, creates
   source `.tar.gz` and `.zip` archives, calculates SHA-256 checksums, and
   publishes the GitHub Release.

Use labels consistently because GitHub groups the generated changelog using
`.github/release.yml`. Apply `skip-changelog` only to changes that should not
appear in public release notes.

Do not reuse or move an existing release tag. If a release workflow fails after
pushing its tag, rerunning the workflow completes the release from that existing
tag instead of moving it to a newer commit.

The release archives contain source code only. Do not attach platform binaries
until they are built from the tagged commit and validated on their target
platform.

Test fixtures remain in the repository because the Odin test suite and CI use
them, but `.gitattributes` excludes `tests/fixtures/` and the Python C ABI smoke
test from release archives. Fixture generators in `tools/` remain included so
contributors can recreate benchmark and test data when needed.

## Repository Metadata

Recommended GitHub metadata:

- Description: `Local columnar analytics for CSV, JSONL, logs, and .snout files`
- Topics: `odin`, `columnar`, `analytics`, `csv`, `jsonl`, `logs`, `cli`,
  `embedded-database`
- Website: project documentation or release page when available

Keep the repository license set to AGPL-3.0 and ensure GitHub recognizes
`LICENSE`.

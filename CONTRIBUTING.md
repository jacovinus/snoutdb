# Contributing to SnoutDB

Thank you for helping improve SnoutDB. This project prioritizes:

1. Correctness
2. Simplicity
3. Maintainability
4. Performance

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.
Maintainers should also follow the
[Repository Guide](docs/REPOSITORY-GUIDE.md).

## Before You Start

- Search existing issues before opening a new one.
- Use an issue for behavior changes, new commands, file-format changes, or
  substantial refactors.
- Small fixes, tests, and documentation corrections may go directly to a pull
  request.
- Do not include generated fixtures, build outputs, local dependencies, or
  private data.

## Development Setup

SnoutDB requires a current Odin toolchain. Follow the
[official Odin installation guide](https://odin-lang.org/docs/install/), then
build and test from the repository root:

```bash
odin build ./cmd/snout -out:snout
odin test ./tests -out:tests/snout_tests -vet -strict-style
```

Run the complete pre-release validation before requesting review:

```bash
./scripts/validate-release.sh
```

The validation covers the CLI, ingestion formats, storage, sniff, Hunt and its
report exports, query, transform, merge, rollup, the C ABI, and available
language examples.

## Repository Structure

| Path | Responsibility |
|---|---|
| `core/` | Shared table, column, error, and version types |
| `ingest/` | CSV, JSONL, and log readers |
| `storage/` | `.snout` reader, writer, and format |
| `sniff/` | Profiling, roles, statistics, and suggestions |
| `hunt/` | Automatic analyzers, ranking, evidence, terminal reports, and exports |
| `query/`, `exec/` | Filtering, grouping, sorting, and aggregates |
| `transform/` | Column transformations |
| `merge/` | Append, consolidate, compact, and rollup |
| `output/`, `terminal/` | Result rendering |
| `cabi/`, `include/` | Experimental C ABI |
| `cmd/snout/` | CLI entry point and command handling |
| `tests/` | Automated tests and small fixtures |
| `benchmarks/` | Performance-sensitive validation |

See [ARCHITECTURE.md](ARCHITECTURE.md) before changing package boundaries,
ownership, ingestion, query execution, or the `.snout` format.

## Branches

Create a short-lived branch from `main`:

```text
feat/short-description
fix/short-description
docs/short-description
perf/short-description
refactor/short-description
test/short-description
```

Keep one logical change per branch. Avoid mixing cleanup or unrelated
refactors into a feature or bug fix.

## Commits

Use concise Conventional Commit messages:

```text
feat(query): add multi-column grouping
fix(storage): reject truncated dictionary indices
docs(readme): explain the snout format
test(jsonl): cover file changes between passes
perf(sniff): reduce cardinality allocations
```

Allowed common types:

- `feat`: new user-facing behavior
- `fix`: bug fix
- `docs`: documentation only
- `test`: tests only
- `perf`: measured performance improvement
- `refactor`: behavior-preserving code change
- `build`: build or dependency changes
- `ci`: continuous integration changes
- `chore`: repository maintenance

Use the imperative mood, keep the subject focused, and explain motivation or
tradeoffs in the commit body when they are not obvious.

Do not include secrets, personal datasets, generated binaries, dependency
folders, or large generated fixtures in commits.

## Code Guidelines

- Use explicit allocators and preserve ownership rules.
- Keep data column-oriented and avoid per-row allocations in hot paths.
- Return `snout_core.Error` values instead of hiding failures.
- Keep package dependencies acyclic.
- Prefer established local patterns over new abstractions.
- Avoid networking, distributed-system concepts, SQL compatibility layers, and
  ORM concepts.
- Add comments only when the code cannot explain the constraint itself.

## Tests and Benchmarks

Every behavior change must include tests. Tests must:

- reproduce a bug before fixing it;
- cover success and relevant failure paths;
- release allocated memory cleanly;
- use small deterministic fixtures where possible.

Run:

```bash
odin test ./tests -out:tests/snout_tests -vet -strict-style
```

Changes to ingestion, storage, sniff, Hunt analysis, query execution, merge, or
other hot paths should include or update a benchmark. Report before/after
measurements and the hardware or environment used.

Hunt changes should cover deterministic ranking, color-disabled output,
structured output, and any affected compact/verbose report layout. Export
changes must verify that TXT and Markdown files contain no ANSI sequences.

## Documentation

Update documentation when changing:

- CLI commands, flags, or output;
- supported input formats;
- the `.snout` file format;
- C ABI functions or ownership;
- performance characteristics;
- Hunt analyzers, ranking, report fields, or export formats;
- completed or planned features.

Keep `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md`, and relevant RFC/spec
documents consistent.

## Pull Requests

A pull request should:

- solve one clearly described problem;
- explain the behavior before and after the change;
- reference related issues;
- include tests and benchmarks when applicable;
- include documentation updates;
- pass CI and `./scripts/validate-release.sh`;
- avoid generated or unrelated changes.

Draft pull requests are welcome for early design feedback. Mark the PR ready
only when the implementation and validation are complete.

Maintainers may request smaller scope, additional tests, benchmark evidence, or
documentation before merging. Prefer squash merging so `main` keeps one clear
commit per reviewed change.

## Release Changes

Normal pull requests must not change `VERSION`. A release preparation pull
request updates `VERSION`, the curated `CHANGELOG.md`, and any version references
that changed. After that pull request is merged to `main`, automation creates
the matching tag and GitHub Release if the tag does not already exist.

Release notes are generated from merged pull requests. Apply an accurate label
(`enhancement`, `bug`, `performance`, `documentation`, or `breaking-change`) and
write a PR title that makes sense in a public changelog. Use `skip-changelog`
only for internal maintenance that users do not need to see.

## Compatibility Changes

SnoutDB is pre-`v1.0.0`, but compatibility changes still require explicit
review. Highlight changes to:

- CLI syntax or output contracts;
- `.snout` format versions or encodings;
- persisted type semantics;
- the C ABI or `snoutdb.h`;
- result column naming.

Describe migration impact and update `CHANGELOG.md`.

## Licensing

By submitting a contribution, you agree that it may be distributed under the
repository's [GNU Affero General Public License v3](LICENSE).

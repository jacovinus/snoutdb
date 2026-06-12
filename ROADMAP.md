# SnoutDB Roadmap

This roadmap communicates direction rather than fixed delivery dates. GitHub
Issues and Milestones track work that has concrete scope and acceptance
criteria.

## v0.2.x: Hunt and CLI Stabilization

- Harden malformed-input and corrupted-file handling.
- Stabilize Hunt's table, JSON, JSONL, TXT, and Markdown contracts.
- Benchmark Hunt against representative CSV, JSONL, log, and `.snout` inputs.
- Evaluate bounded-memory or staged Hunt execution for large raw inputs.
- Add configuration only after its precedence and validation contract is
  implemented and tested.
- Publish repeatable performance and memory baselines.
- Expand CI beyond macOS.
- Clarify compatibility expectations for `.snout` files and the C ABI.

## Query and Storage Efficiency

- Evaluate chunk skipping using existing per-chunk min/max statistics.
- Reduce memory used by grouped queries and exact percentiles.
- Improve repeated-query workflows over `.snout` files.
- Expand transformations only where real workflows justify them.
- Continue hardening the experimental C ABI.

## Toward v1.0.0

- Define stable CLI and output contracts.
- Publish a formal `.snout` compatibility policy.
- Stabilize or explicitly version the C ABI.
- Establish supported operating systems and architectures.
- Maintain reproducible benchmarks across releases.
- Document migrations for every breaking change.

## Non-Goals

SnoutDB does not currently aim to become:

- a distributed database;
- a network database server;
- a SQL compatibility layer;
- an ORM;
- a general-purpose transactional database.

Proposals should start with a concrete local analytics workflow. Use GitHub
Discussions for design exploration and Issues for accepted, actionable work.

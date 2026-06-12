# RFC-0011 Hunt Analytics, Severity, and Configuration

## Status

Partially implemented in v0.2.0.

Implemented: severity normalization, frequent context, log message templates,
severity-aware findings, deterministic ranking, shell-safe reproduction
commands, terminal color modes, compact and verbose charts, JSON/JSONL output,
and TXT/Markdown export.

Deferred: global/project TOML configuration, configurable weights and colors,
and persistent historical baselines. Sections describing those features remain
design proposals and are not part of the v0.2.0 CLI.

## Summary

This RFC evolves `snout hunt` from a generic ranked-finding engine into an
analytical workflow for unfamiliar datasets and logs.

Hunt must answer three different questions:

1. What happens most frequently?
2. What deserves attention?
3. What command should the user run next to investigate it?

For logs, frequency alone is not sufficient. A large volume of `INFO` messages
is useful context, but it should not outrank a smaller set of errors, a new
warning pattern, or a sudden severity spike.

The proposed output separates descriptive context from noteworthy findings,
includes representative messages in every log-oriented suggestion, applies
severity-aware ranking, supports terminal colors without polluting structured
output, and introduces user-configurable Hunt settings.

This RFC extends `tasks/SPEC-0015-hunt.md`. It does not change the `.snout` file
format.

## Motivation

The current Hunt implementation has several product and correctness gaps:

- `INFO` concentration can appear more important than an error pattern.
- Findings do not provide a frequent-message overview.
- Suggestions can mention only `level` and count, which does not identify the
  underlying problem.
- Log messages with variable IDs, URLs, timestamps, and numbers fragment into
  separate values.
- Reproduction commands are not consistently shell-safe.
- Output and input format flags conflict for log inputs.
- Table output does not visually distinguish severity.
- There is no persistent configuration for thresholds, colors, or display
  preferences.

Hunt is an analytical command. Its primary value is not counting rows; it is
helping the user identify a problem and continue investigating it.

## Goals

- Keep a visible summary of frequent levels and message patterns.
- Rank errors, warnings, temporal changes, rare patterns, and new patterns above
  routine informational volume.
- Include a representative message in every log-oriented finding and
  suggestion.
- Normalize common log levels into a stable severity model.
- Cluster variable messages into deterministic templates.
- Provide valid, shell-safe reproduction commands.
- Produce useful output with or without color.
- Keep JSON and JSONL stable, ANSI-free, and machine-readable.
- Support global and project-local configuration.
- Preserve deterministic results for the same input and configuration.
- Keep the system explainable and free from an LLM dependency.

## Non-Goals

- Interactive full-screen TUI.
- Arbitrary machine-learning clustering.
- Natural-language root-cause claims without evidence.
- Persistent historical baselines across machines in the first implementation.
- Replacing `snout sniff` or explicit queries.
- Adding terminal escape sequences to JSON, JSONL, or redirected table output.

## Product Model

Hunt output has three sections.

### 1. Frequent Context

This section is descriptive. It shows what is common without claiming that it
is anomalous.

For logs it includes:

- normalized level;
- representative message template;
- count;
- share of total rows;
- first occurrence;
- last occurrence.

Example:

```text
Frequent patterns

LEVEL  COUNT  SHARE  FIRST                 LAST                  MESSAGE
INFO    4821  72.1%  2026-06-12T07:00:01Z 2026-06-12T10:14:52Z  Start telemetry events
WARN     218   3.3%  2026-06-12T07:24:47Z 2026-06-12T10:12:09Z  Failed to fetch access token
ERROR     37   0.6%  2026-06-12T10:42:03Z 2026-06-12T10:46:11Z  POST threw: {error_code}
```

Frequent context has a separate limit and does not consume the finding limit.

### 2. Needs Attention

This section contains ranked findings. Severity, rarity, growth, coverage,
confidence, and reproducibility determine ranking.

Example:

```text
Needs attention

[92 ERROR] Network I/O suspended
  Message: [EventLogging] POST threw: Error: net::ERR_NETWORK_IO_SUSPENDED
  Why: 37 events in 4 minutes; frequency increased 8.4x.
  First seen: 2026-06-12T10:42:03Z
  Last seen:  2026-06-12T10:46:11Z
  Investigate:
    snout -f warp.log group=timestamp,message -- count=rows \
      --where message contains ERR_NETWORK_IO_SUSPENDED
```

### 3. Suggestions

Suggestions are actionable next steps. Every log-oriented suggestion must
include:

- the normalized level when available;
- a representative message or template;
- the reason it was selected;
- a valid command;
- whether the command exactly or approximately reproduces the evidence.

A suggestion that says only "count rows by level" is insufficient.

## Severity Model

### Normalized levels

Input values are matched case-insensitively and normalized:

| Inputs | Normalized | Rank |
|---|---|---:|
| `trace` | `TRACE` | 0 |
| `debug`, `dbg` | `DEBUG` | 1 |
| `info`, `information`, `notice` | `INFO` | 2 |
| `warn`, `warning` | `WARN` | 3 |
| `error`, `err` | `ERROR` | 4 |
| `fatal`, `critical`, `crit`, `panic`, `emerg`, `alert` | `CRITICAL` | 5 |

Unknown values remain `UNKNOWN` and retain the original value as evidence.
An unknown level may be interesting when rare or newly observed.

### Default display styles

| Level | Truecolor | ANSI 256 fallback | Basic fallback |
|---|---|---|---|
| `TRACE` | `#808080` | gray | dim |
| `DEBUG` | `#8A8A8A` | gray | dim |
| `INFO` | `#32CD70` | green | green |
| `WARN` | `#FFA500` | orange | yellow |
| `ERROR` | `#FF5A36` | orange-red | red |
| `CRITICAL` | `#FF0000` bold | bright red bold | bright red bold |
| `UNKNOWN` | terminal default | terminal default | terminal default |

Color is supplementary. Level text, score, and reason must carry the same
meaning when color is disabled.

### Color policy

CLI:

```bash
snout hunt app.log --color auto
snout hunt app.log --color always
snout hunt app.log --color never
```

Rules:

- `auto`: color only when stdout is a TTY and `NO_COLOR` is not set.
- `always`: emit color in table output even when redirected.
- `never`: never emit color.
- `NO_COLOR` overrides `auto`, but not an explicit `--color always`.
- JSON and JSONL never contain ANSI escapes.

## Log Message Templates

Exact-message grouping fragments operationally identical messages. Hunt will
derive a deterministic template for analysis while preserving a representative
original message.

Initial normalizations:

- UUIDs -> `{uuid}`
- IPv4 and IPv6 addresses -> `{ip}`
- URLs -> `{url}`
- ISO timestamps -> `{timestamp}`
- long hexadecimal identifiers -> `{hex}`
- standalone integers and decimals -> `{number}`
- quoted opaque identifiers above a configurable length -> `{id}`

Example:

```text
Session local_852192f6-d6de-449e-a2e2-898a38b54d68 exited
Session local_61f08ca5-301d-4930-b2e8-982ee177939e exited
```

becomes:

```text
Session {id} exited
```

Requirements:

- normalization is deterministic;
- original messages are never mutated;
- one representative message is retained per template;
- no per-row heap allocation in the hot path where avoidable;
- templates are bounded in length;
- replacement rules are ordered and tested to avoid overlapping corruption.

## Log Analysis

### Frequent Pattern Analyzer

Produces the Frequent Context section, not ranked findings.

For each `(normalized_level, message_template)`:

- count;
- share;
- first timestamp;
- last timestamp;
- representative message.

Default limit: 10 patterns.

### Severity Summary Analyzer

Produces counts and shares by normalized level.

Routine `INFO`, `DEBUG`, and `TRACE` concentration is context, not a finding.
It becomes noteworthy only when:

- its volume changes sharply;
- it is a previously unseen pattern;
- it correlates with errors or warnings;
- the level value is unknown or malformed.

### Error and Warning Pattern Analyzer

Ranks templates with `WARN`, `ERROR`, or `CRITICAL` using:

- severity;
- count;
- share within the level;
- first/last timestamp;
- burstiness;
- temporal growth;
- rarity relative to other patterns.

Warnings receive less severity weight than errors but can rank highly when
frequent, new, or rapidly growing.

### Temporal Severity Shift Analyzer

Tracks counts per time bucket for each severity and template.

Detects:

- error-rate increase;
- warning-rate increase;
- new critical pattern;
- burst of one message template;
- disappearance or recovery after a spike.

The implementation must calculate even-sized medians correctly and compare the
spike bucket to an actual prior or baseline bucket.

### Existing Analyzer Changes

`Concentration`:

- may still report frequent values for generic datasets;
- must not emit `INFO`, `DEBUG`, or `TRACE` level concentration as an attention
  finding;
- message concentration moves to Frequent Context unless severity or change
  makes it noteworthy.

`Error_Hotspot`:

- normalize levels case-insensitively;
- distinguish warning from error severity;
- support message templates as evidence;
- include representative messages.

`Metric_Outlier`:

- title and evidence must identify the trigger actually used (`p99/p50` or
  `max/p95`);
- reproduction must work for the source type.

`Temporal_Shift`:

- use a correct median for even bucket counts;
- report the actual baseline comparison;
- support severity/template-specific shifts.

## Ranking

Generic dataset findings retain the current effect/coverage/confidence/novelty
model.

Log findings add severity and growth:

```text
score =
    severity   * 0.30 +
    effect     * 0.20 +
    growth     * 0.20 +
    novelty    * 0.15 +
    coverage   * 0.10 +
    confidence * 0.05
```

Default severity component:

| Level | Score |
|---|---:|
| `TRACE` | 0 |
| `DEBUG` | 5 |
| `INFO` | 10 |
| `WARN` | 55 |
| `ERROR` | 85 |
| `CRITICAL` | 100 |
| `UNKNOWN` | 35 |

Ranking rules:

1. Critical and error findings outrank routine informational frequency.
2. A sharp warning spike may outrank a stable low-volume error.
3. New patterns receive novelty credit.
4. Small samples reduce confidence but do not erase severe findings.
5. Equivalent findings for the same template and interval are deduplicated.
6. Frequent Context is sorted independently by count.

## Suggestions

Each log finding contains a structured suggestion:

```odin
Hunt_Suggestion :: struct {
    title:                  string,
    reason:                 string,
    level:                  Log_Level,
    message:                string,
    message_template:       string,
    command:                string,
    reproduction_is_exact:  bool,
}
```

Suggested commands prefer stable fragments over full variable messages:

```bash
snout -f warp.log group=timestamp,message -- count=rows \
  --where level eq ERROR \
  --where message contains ERR_NETWORK_IO_SUSPENDED
```

Commands must:

- use the correct input loader;
- carry `--logformat` and `--logpattern` when required;
- quote shell arguments safely;
- avoid `snout stats` for CSV, JSONL, or logs when it only accepts `.snout`;
- be executable in supported shells for ordinary paths and values.

## CLI Contract

Proposed command:

```text
snout hunt <input>
  [--limit <n>]
  [--frequent-limit <n>]
  [--min-score <0..100>]
  [--format table|json|jsonl]
  [--logformat clf|combined|logfmt|syslog|app|regex]
  [--logpattern <pattern>]
  [--strict]
  [--color auto|always|never]
  [--config <path>]
  [--no-config]
  [--verbose]
  [-o <report.txt|report.md>]
```

`--format` controls output only. `--logformat` controls log parsing only.
`-o` / `--output` writes a color-free text report for `.txt` paths or a
structured Markdown report for `.md` paths. `--verbose` also controls the
detail level of exported reports.

## Configuration

### Locations

1. Explicit `--config <path>`
2. Project-local `.snout.toml`, searched from current directory only
3. Global config:
   - Unix/macOS: `${XDG_CONFIG_HOME:-~/.config}/snout/config.toml`
   - Windows: `%APPDATA%\snout\config.toml`
4. Built-in defaults

Precedence:

```text
CLI flags > explicit config > .snout.toml > global config > defaults
```

`--no-config` disables all file-based configuration.

### Example

```toml
[hunt]
limit = 10
frequent_limit = 10
min_score = 60
show_frequent = true
min_attention_level = "warn"

[hunt.weights]
severity = 0.30
effect = 0.20
growth = 0.20
novelty = 0.15
coverage = 0.10
confidence = 0.05

[hunt.templates]
normalize_uuid = true
normalize_ip = true
normalize_url = true
normalize_timestamp = true
normalize_numbers = true
max_template_length = 240

[output]
color = "auto"
unicode = true

[levels.trace]
color = "#808080"
bold = false

[levels.debug]
color = "#8A8A8A"
bold = false

[levels.info]
color = "#32CD70"
bold = false

[levels.warn]
color = "#FFA500"
bold = true

[levels.error]
color = "#FF5A36"
bold = true

[levels.critical]
color = "#FF0000"
bold = true
```

### Configuration validation

- Unknown top-level sections produce a warning in table mode.
- Invalid values produce a clear error and non-zero exit.
- Weight values must be finite and non-negative.
- Weights are normalized to sum to 1.0.
- Invalid colors identify the exact key.
- JSON output diagnostics go to stderr.

The implementation should use a structured TOML parser. It must not parse TOML
with ad hoc string splitting.

## Structured Output

JSON:

```json
{
  "table": {"name": "warp", "rows": 6689},
  "severity_summary": [
    {"level": "INFO", "count": 4821, "share": 0.721}
  ],
  "frequent_patterns": [
    {
      "level": "WARN",
      "message": "Failed to fetch access token",
      "message_template": "Failed to fetch access token",
      "count": 218,
      "share": 0.033,
      "first_seen": "2026-06-12T07:24:47Z",
      "last_seen": "2026-06-12T10:12:09Z"
    }
  ],
  "findings": [
    {
      "type": "log_pattern_spike",
      "score": 92,
      "severity": "ERROR",
      "message": "[EventLogging] POST threw: Error: net::ERR_NETWORK_IO_SUSPENDED",
      "message_template": "[EventLogging] POST threw: Error: {error_code}",
      "reason": "37 events in 4 minutes; frequency increased 8.4x",
      "first_seen": "2026-06-12T10:42:03Z",
      "last_seen": "2026-06-12T10:46:11Z",
      "reproduce": {
        "command": "snout -f warp.log ...",
        "exact": true
      }
    }
  ]
}
```

JSONL emits one typed record per line with a `record_type` field:

- `severity_summary`
- `frequent_pattern`
- `finding`

## Error Handling and Compatibility

- Output format must never influence input parsing.
- Unsupported log formats fail before analysis.
- Configuration errors fail before loading the dataset.
- Existing `--limit`, `--min-score`, and output formats remain supported.
- Table output changes are user-visible and must be listed in the changelog.
- JSON output is pre-1.0 but should gain a `schema_version` field before this RFC
  is implemented.

## Performance

- Frequent-pattern aggregation should use one pass over log columns.
- Candidate templates are bounded by configurable cardinality.
- Template normalization should avoid regex compilation per row.
- Default Hunt runtime target remains no more than 3x equivalent sniff runtime
  on standard fixtures.
- Configuration loading must be negligible relative to ingestion.

## Security

- Reproduction commands are display strings and must be shell-escaped.
- ANSI sequences from input data must be stripped or escaped in table output.
- User-supplied color configuration cannot inject arbitrary control sequences.
- Config file parsing must reject unsupported value types.

## Acceptance Criteria

- Frequent levels and messages are visible in table and structured output.
- `INFO`, `DEBUG`, and `TRACE` frequency is context, not an attention finding.
- `WARN`, `ERROR`, and `CRITICAL` findings include representative messages.
- Every log suggestion includes a message or message template.
- Color follows `auto|always|never` and `NO_COLOR`.
- JSON and JSONL contain no ANSI escapes.
- Global and local TOML configuration follow documented precedence.
- Reproduction commands work for CSV, JSONL, logs, and `.snout`.
- Input and output format flags cannot conflict.
- Ranking is deterministic for fixed input and configuration.

## Changelog Entry Proposal

Do not add this entry until the RFC is implemented and validated:

```markdown
### Added

- Expanded `snout hunt` with severity-aware log analysis, frequent message
  patterns, actionable message-based suggestions, configurable terminal colors,
  and global/project TOML settings.

### Fixed

- Separated Hunt input log format from output format, corrected temporal and
  metric finding descriptions, and generated shell-safe reproduction commands.
```

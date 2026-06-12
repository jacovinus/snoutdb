# SnoutDB Launch Copy

This document contains editable launch drafts. Check the current release,
supported platforms, benchmark results, and links immediately before posting.

## Hacker News

### Suggested title

```text
Show HN: SnoutDB – Hunt through unfamiliar logs and datasets locally
```

### Suggested first comment

```text
Hi HN,

Most analytics tools assume you already know the schema and what you want to
ask. I built SnoutDB for the investigation before that.

The main workflow in v0.2.0 is:

    snout hunt application.log

Hunt summarizes severity and frequent patterns, ranks findings, shows temporal
histograms, and prints commands that reproduce the evidence. `--verbose` adds
peaks, first/last matches, representative samples, and detailed reproduction
commands. Reports can be exported directly:

    snout hunt application.log --verbose -o report.md

For lightweight schema discovery, `snout sniff -f <file>` still classifies
columns, profiles values, and suggests useful queries.

The honest comparison is that DuckDB is much more capable once you know what to
ask. Miller and qsv are more mature for established command-line data
pipelines, and VisiData is better for interactive exploration. SnoutDB's
specific bet is that an automatic, explainable reconnaissance pass can shorten
the path from "what is this file?" to evidence worth investigating.

After discovery, SnoutDB can query the raw file directly or persist it as a
typed, chunked `.snout` snapshot for repeated queries, transformations, merges,
and rollups. The implementation is written in Odin and also exposes an
experimental C ABI.

Current status: v0.2.0, 343 tests, macOS CI. The CLI, C ABI and file format are
still pre-1.0. A reproducible 5M-row CSV benchmark and the current limitations
are documented in the repository.

The question I would especially value feedback on is:

Does Hunt surface evidence that helps with the operational files you actually
work with, or does its ranking still miss what matters?

Repository: https://github.com/jacovinus/snoutdb
```

### Posting checklist

- Use a `Show HN:` title and link directly to the repository.
- Be available to answer technical questions for several hours.
- State limitations directly instead of defending every design choice.
- Do not ask for upvotes or coordinate voting.
- Answer comparisons with DuckDB, Polars, Miller, jq, and SQLite concretely.
- Correct benchmark or compatibility mistakes publicly.

## LinkedIn

### Suggested post

```text
📁 Someone sends you a log or dataset.

No documentation.
Unclear columns.
Millions of rows.
And one simple question: “What is actually in here?”

That is why I built SnoutDB. 🐽

SnoutDB investigates unfamiliar CSV, JSONL, log, and `.snout` files before you
know what query to write.

Run:

snout hunt application.log

It will:

🔎 summarize severity and frequent patterns
📊 visualize activity over time
⚠️ rank findings that deserve attention
💡 preserve evidence and reproduction commands
⚡ print commands you can run immediately

For example, SnoutDB can identify repeated error templates, show when they
occurred, and print the command needed to investigate them.

No server. No account. No data upload.

Just point it at the file and start investigating.

📁 UNKNOWN FILE → 🔎 HUNT → ⚠️ RANKED EVIDENCE

Is it a replacement for DuckDB? No.

DuckDB is the stronger tool when you know the question and need SQL, joins, and
broad analytical power.

SnoutDB is for the step before that.

It is open source, written in Odin, and v0.2.0 is ready to try:

👉 https://github.com/jacovinus/snoutdb

I would love to test it against the messiest operational file you regularly
receive. What would you throw at it?

#opensource #dataengineering #odinlang
```

### Short version

```text
📁 Someone sends you a CSV.

No documentation. Unclear columns. Millions of rows.

What is actually in it?

That is why I built SnoutDB. 🐽

Run:

snout hunt application.log

🔎 Severity and pattern summaries
📊 Temporal histograms
⚠️ Ranked findings
💡 Reproducible investigation commands

📁 UNKNOWN FILE → ⚠️ RANKED EVIDENCE

Open source, written in Odin, and ready to try:

👉 https://github.com/jacovinus/snoutdb

#opensource #dataengineering #odinlang
```

### LinkedIn formatting notes

- LinkedIn does not render Markdown. Do not paste backticks, Markdown headings,
  or fenced code blocks into the post editor.
- Keep the first two or three lines short because they appear before
  “...more”.
- Use blank lines to separate ideas; avoid paragraphs longer than three lines.
- Use emojis as visual labels, not as decoration on every sentence.
- Prefer plain text over decorative Unicode bold or italic characters, which
  are less accessible and harder to search.
- Add the repository URL once, near the end.
- Attach one visual separately rather than trying to draw a terminal in text.

## Suggested Visuals

For LinkedIn, use one image rather than a screenshot collage:

1. Terminal screenshot showing `snout hunt --verbose`.
2. A clean architecture diagram exported from the README Mermaid chart.
3. A simple card with: “Unknown file → useful query” and the repository URL.

Avoid leading with benchmark numbers alone. The product story is identifying
what deserves attention in an unfamiliar local file.

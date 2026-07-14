# CCStat

A small, always-on-top macOS overlay that shows **Claude Code** and **Codex**
usage in one place — limits, token totals, top sessions, and live/idle session
counts. Minimal, draggable, resizable, and it never costs API tokens (it only
reads local log files).

## What it shows

- **Limits** — Codex 5h / weekly usage as a real percentage (Codex writes its
  rate-limit state to its own logs), with reset countdowns. Claude Code does
  **not** store limit percentages locally, so Claude shows token volume per
  window instead.
- **Totals** — combined and per-provider tokens for today / week / lifetime.
  Headline figures are **non-cache** generation tokens (input + output), so they
  match what the Claude app reports; cache reads are shown as a footnote.
- **Top sessions** — where the tokens are going, labeled `project·id`.
- **Sessions** — open / running / idle counts from live CLI processes.

## How it works

- `agg.py` — a stdlib-only Python aggregator that scans
  `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`, aggregates
  usage with an incremental mtime cache (fast refreshes despite GBs of logs),
  and writes `~/Library/Application Support/CCStat/stats.json`.
- `Sources/main.swift` — a SwiftUI floating `NSPanel` (borderless, high window
  level, joins all Spaces) that renders `stats.json`. It auto-refreshes every
  60s and on the refresh button, running the bundled `agg.py`.

## Build & run

```sh
bash build.sh            # compiles CCStat.app (needs Xcode command-line tools)
open CCStat.app
```

To keep it running at login, add `CCStat.app` to **System Settings → General →
Login Items**.

## Scope

Token totals include anything that writes to the local Claude/Codex log
directories (including the Claude desktop app). Live-session counts are local
CLI processes only — **cloud/remote sessions run server-side and leave no local
trace**, so they can't be shown.

## Requirements

macOS 13+, Xcode command-line tools (`swiftc`), Python 3 (system
`/usr/bin/python3` is fine).

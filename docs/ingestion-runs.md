# Ingestion Runs

`/ingestion_runs` is the operations view for ingestion. It's where you check
"is everything caught up?" and where you go to retry a stuck file.

## What you see

Each row is one run of `SessionsSweepJob` or `IngestSessionFileJob`:

- **Source** — sweep, watcher, or manual.
- **Status** — `running`, `succeeded`, or `failed`.
- **File / sweep target** — the JSONL file, or "all files" for a sweep.
- **Counts** — files processed, messages upserted, errors.
- **Duration** — how long the run took.

Failed runs include the exception message. Common causes:

- Malformed JSONL (an agent was caught mid-write on a partial line)
- A compressed Codex rollout when the `zstd` binary isn't installed
- Schema mismatches after a migration you haven't applied
- A linked PR's `gh pr view` call timing out (these run as separate jobs but
  surface as enrichment failures on the affected `pr_links`)

## Retrying

Each failed row has a **Retry** button (`POST /ingestion_runs/:id/retry`)
which re-enqueues the same job with the same arguments. For per-file failures
this is usually all you need; for sweep-level failures it's often easier to
run `bin/rails sessions:ingest` and watch the logs.

## When the page is empty

If `/ingestion_runs` shows nothing on a fresh install:

- Make sure the worker is running. `bin/dev` starts it; `bin/rails server`
  alone does not.
- Make sure `~/.claude/projects/` exists and contains `.jsonl` files. The
  watcher aborts on startup if the directory is missing.
- Check `AUTO_INGEST` isn't set to `false`.

See [Troubleshooting](troubleshooting.md) for the full checklist.

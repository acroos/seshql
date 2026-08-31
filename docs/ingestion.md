# Ingestion

SeshQL reads the JSONL files Claude Code writes to `~/.claude/projects/`. Each
file is one session; each line is one message event. Ingestion parses the
file, normalizes events into the SeshQL schema, and upserts them into Postgres.

## How files reach the database

Three triggers all funnel into the same code path
(`Sessions::Ingester.call(file_path)` →
`IngestSessionFileJob` → upserted rows):

1. **Boot sweep.** When the Rails server starts, an initializer enqueues a
   `SessionsSweepJob` that scans every `*.jsonl` under `~/.claude/projects/`.
   Set `AUTO_INGEST=false` to skip it.
2. **File watcher.** `bin/watch` (started by `bin/dev`) listens for new and
   modified `.jsonl` files and enqueues an `IngestSessionFileJob` per change.
   This is what gives you the "live as Claude Code runs" behavior.
3. **Recurring sweep.** `config/recurring.yml` runs `SessionsSweepJob` every
   5 minutes as a backstop in case the watcher missed a file.

The sweep tracks each file's mtime and size, so re-runs only touch files
that actually changed.

## Manual ingestion

```bash
bin/rails sessions:ingest        # run one sweep now (foreground)
bin/rails sessions:reingest      # delete every session row, then sweep
bin/rails sessions:backfill_aggregates  # recompute costs + cached stats in place
```

Use `reingest` after schema changes or if you want to rebuild from scratch.
It only clears SeshQL's tables — the underlying JSONL files are untouched.

## What gets extracted

Each JSONL line becomes one `messages` row plus a polymorphic detail row:

| JSONL `type` | Detail table |
| --- | --- |
| `user` | `user_prompts` |
| `assistant` | `assistant_messages` + `content_blocks` (one per block) |
| `tool_result` | `tool_results` |
| `system` | `system_events` |
| `attachment` | `attachments` |

Cross-cutting tables are populated as side effects:

- **`pr_links`** — when a message references a PR URL, an `EnrichPrLinkJob`
  runs `gh pr view` to fill in the title and repo.
- **`file_history_snapshots`** — Claude Code's periodic file snapshots are
  preserved so you can ask "what files were tracked at this point?"
- **`repos`** — `ResolveRepoJob` reads `git remote -v` for each session's
  `cwd` and links the session to a repo row.

## Background workers

Ingestion runs through Solid Queue, so jobs persist across restarts. The
`worker` line in `Procfile.dev` starts `bin/jobs`, which is what `bin/dev`
launches alongside the web server. If you start the server manually
(`bin/rails server`), nothing will get ingested until you also run
`bin/jobs` in another terminal.

## Where to look when something is wrong

- `/ingestion_runs` shows the status of recent sweeps and per-file failures
  with retry buttons. See [Ingestion Runs](ingestion-runs.md).
- Job logs are in `log/development.log` — search for `[auto_ingest]`,
  `[watch]`, or `IngestSessionFileJob`.

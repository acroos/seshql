# Troubleshooting

## Nothing is ingested

1. **Is `~/.claude/projects/` populated?** That's the only directory SeshQL
   reads. If you've never run Claude Code, there's nothing to ingest.
2. **Is the worker running?** `bin/dev` starts the web server, the worker
   (`bin/jobs`), and the file watcher (`bin/watch`). If you started the
   server with `bin/rails server`, jobs sit in the queue and never run.
3. **Is `AUTO_INGEST` disabled?** Setting `AUTO_INGEST=false` skips the
   boot-time sweep. Either unset it or run `bin/rails sessions:ingest`.
4. **Is the file watcher stuck?** It logs `[watch] watching <dir>` once and
   then `[watch] enqueued N` on each change. Restart `bin/dev` if it's silent.
5. **Manual sweep.** Run `bin/rails sessions:ingest` and watch the output —
   any errors will surface there and on `/ingestion_runs`.

## "no projects dir at /Users/.../claude/projects"

`bin/watch` aborts if `~/.claude/projects/` doesn't exist. Run Claude Code
once to create it, or `mkdir -p ~/.claude/projects` if you're testing.

## Postgres connection errors

`docker compose up -d` brings up Postgres on port `5433` with credentials
`seshql` / `seshql`. If you're running Postgres yourself, override with
`DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`.

A note on the `gssencmode: disable` line in `config/database.yml`: it works
around a known SEGV in `pg 1.6.3` on macOS arm64. Don't remove it unless
you've confirmed the upstream fix is in place.

## PR titles are missing

PR enrichment runs `gh pr view <number> --repo <owner/repo>` in a job. It
needs:

- `gh` installed and on `PATH`.
- `gh auth login` (or `GH_TOKEN` set) with access to the repo.

Backfill after fixing auth: `bin/rails sessions:backfill_pr_titles`.

## SQL Console rejects my query

The console only runs `SELECT` and `WITH` queries, one statement at a time.
Anything matching `INSERT|UPDATE|DELETE|DROP|...` is blocked even inside
strings or comments. If you need write access, use `bin/rails dbconsole`.

If your query times out, it hit the 10s `statement_timeout`. Add a `WHERE`
clause or pre-aggregate in a CTE.

## Resetting everything

```bash
bin/rails sessions:reingest      # wipes session/message tables, re-ingests
bin/rails db:drop db:create db:migrate  # nuke from orbit
```

Both leave the JSONL files on disk untouched.

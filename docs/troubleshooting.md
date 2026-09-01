# Troubleshooting

## Nothing is ingested

1. **Is any agent directory populated?** SeshQL reads
   `$CLAUDE_HOME/projects/` (default `~/.claude`) and `$CODEX_HOME/sessions/`
   (default `~/.codex`). If you've run neither agent, there's nothing to
   ingest. An agent you don't have installed is skipped silently, which is
   why the sweep log names the agents it actually found:
   `[sweep] enqueued=... across Claude Code, Codex`.
2. **Is the worker running?** `bin/dev` starts the web server, the worker
   (`bin/jobs`), and the file watcher (`bin/watch`). If you started the
   server with `bin/rails server`, jobs sit in the queue and never run.
3. **Is `AUTO_INGEST` disabled?** Setting `AUTO_INGEST=false` skips the
   boot-time sweep. Either unset it or run `bin/rails sessions:ingest`.
4. **Is the file watcher stuck?** It logs `[watch] watching <dir>` once and
   then `[watch] enqueued N` on each change. Restart `bin/dev` if it's silent.
5. **Manual sweep.** Run `bin/rails sessions:ingest` and watch the output —
   any errors will surface there and on `/ingestion_runs`.

## "no agent session directories found"

`bin/watch` aborts when neither agent's directory exists. Run Claude Code or
Codex once to create one, or point `CLAUDE_HOME` / `CODEX_HOME` at wherever
yours live.

## A Codex session ingested but has no cost

Check `assistant_messages.model` for that session. Cost is `NULL` when the
model has no entry in [`Pricing::Openai`](../app/services/pricing/openai.rb) —
new models appear faster than rate tables do. Add the rate and run
`bin/rails sessions:backfill_aggregates` to reprice without re-reading the
transcripts.

Codex can also run a model in "fast mode" at roughly double the standard rate.
Nothing in the rollout file records which mode a turn used, so SeshQL assumes
standard rates and fast-mode sessions read low.

## A compressed Codex rollout fails to ingest

`/ingestion_runs` shows `CompressedTranscriptUnsupported` when a `.jsonl.zst`
rollout is found and the `zstd` binary isn't on `PATH`. Install it
(`brew install zstd`) and retry the file from that page. Uncompressed rollouts
are unaffected.

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

Both leave the transcripts on disk untouched.

## Schema loading and SQL functions

`content_blocks.bash_command` and `bash_programs` are generated columns whose
expressions call the `shell_command()` and `bash_programs()` SQL functions.
Those functions are managed by the [`fx`](https://github.com/teoljungberg/fx)
gem, live in `db/functions/`, and are dumped into `db/schema.rb`.

`config/initializers/fx_schema_dumper_ordering.rb` moves them ahead of the
tables in the dump. Without that, `db:prepare` and `db:test:prepare` fail on a
fresh database with `function bash_programs(text) does not exist`, because
Postgres resolves a generated column's expression at the moment the column is
created. If you ever see that error, check that the initializer is still in
place and re-run `bin/rails db:schema:dump`.

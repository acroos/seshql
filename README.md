# SeshQL

Query and analyze your coding-agent sessions in Postgres. SeshQL ingests the
JSONL transcripts that **Claude Code** writes to `~/.claude/projects/` and the
rollout files **Codex** writes to `~/.codex/sessions/`, normalizes both into
one relational schema, and gives you a session browser, a SQL console, and
saveable dashboards.

Because both agents land in the same tables, a single query can compare them:
cost per session, tools used, how long each spent working.

## What you can do with it

- **Browse sessions** — search and filter every session either agent has run on
  your machine, filtered by working directory or agent (`/sessions`)
- **Run ad-hoc SQL** — query a normalized schema with a curated set of example
  queries to copy from (`/sql_console`)
- **Build dashboards** — save SQL-backed panels into reusable dashboards
  (`/dashboards`)
- **Watch ingestion** — see which files have been ingested, retry failures
  (`/ingestion_runs`)

See [`docs/`](docs/) for a walk-through of each feature and the data model.

## Quick setup

Prerequisites: macOS or Linux, Ruby 3.3.6, Docker (for Postgres), and the
`gh` CLI authenticated with `gh auth login` (optional — only used to enrich PR
titles).

```bash
# 1. Clone and install gems
git clone <repo-url> seshql
cd seshql
bundle install

# 2. Start Postgres (port 5433, user/password "seshql")
docker compose up -d

# 3. Create + migrate the databases
bin/rails db:prepare

# 4. Run the app
bin/dev
```

Open <http://localhost:3000>. On boot SeshQL sweeps every agent session
directory it finds and ingests the transcripts in the background — the
dashboard will populate within a few seconds. Agents you don't have installed
are simply skipped. Leave Claude Code or Codex running in another terminal and
new sessions show up automatically (the watcher picks up file changes).

That's it. Everything else is in [`docs/`](docs/).

## Common commands

```bash
bin/dev                          # web + worker + file watcher
bin/rails test                   # run the test suite
bin/rails sessions:ingest        # one-shot manual sweep
bin/rails sessions:reingest      # wipe + re-ingest everything
bin/rails sessions:backfill_aggregates  # reprice + recompute cached session stats
bin/rails sessions:backfill_tool_kinds   # re-apply tool-name to tool-kind mapping
bin/rails sessions:backfill_pr_titles
bin/rails sessions:backfill_repos
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_HOST` | `localhost` | Postgres host |
| `DATABASE_PORT` | `5433` | Postgres port (matches `docker-compose.yml`) |
| `DATABASE_USERNAME` | `seshql` | Postgres user |
| `DATABASE_PASSWORD` | `seshql` | Postgres password |
| `AUTO_INGEST` | `true` | Set to `false` to skip the boot-time sweep |
| `CLAUDE_HOME` | `~/.claude` | Where Claude Code keeps `projects/` and `history.jsonl` |
| `CODEX_HOME` | `~/.codex` | Where Codex keeps `sessions/` and `archived_sessions/` |

`CLAUDE_HOME` and `CODEX_HOME` follow the same variables the agents themselves
use, so a non-default install is picked up without extra configuration.

## Adding another agent

Agent-specific parsing lives behind one interface, so supporting a third agent
means adding a class and nothing else. See
[`app/services/sessions/adapters/base.rb`](app/services/sessions/adapters/base.rb)
for the contract and
[`docs/ingestion.md`](docs/ingestion.md#adding-an-agent) for a walk-through.

## Stack

Rails 8 · PostgreSQL 17 · Solid Queue (background jobs) · Solid Cable · Listen
(file watching) · fx (SQL functions in the schema). No Redis, no Node build
step.

Reading Codex's compressed rollouts (`.jsonl.zst`) needs the `zstd` binary on
`PATH`; uncompressed rollouts do not.

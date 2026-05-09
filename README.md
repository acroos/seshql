# SeshQL

Query and analyze your Claude Code sessions in Postgres. SeshQL ingests the
JSONL transcripts that Claude Code writes to `~/.claude/projects/`, normalizes
them into a relational schema, and gives you a session browser, a SQL console,
and saveable dashboards.

## What you can do with it

- **Browse sessions** — search and filter every session Claude Code has run on
  your machine (`/sessions`)
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

Open <http://localhost:3000>. On boot SeshQL sweeps `~/.claude/projects/` for
JSONL files and ingests them in the background — the dashboard will populate
within a few seconds. Leave Claude Code running in another terminal and new
sessions show up automatically (the watcher picks up file changes).

That's it. Everything else is in [`docs/`](docs/).

## Common commands

```bash
bin/dev                          # web + worker + file watcher
bin/rails test                   # run the test suite
bin/rails sessions:ingest        # one-shot manual sweep
bin/rails sessions:reingest      # wipe + re-ingest everything
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

The session directory (`~/.claude/projects/`) is not configurable — it's the
fixed path Claude Code writes to.

## Stack

Rails 8 · PostgreSQL 17 · Solid Queue (background jobs) · Solid Cable · Listen
(file watching). No Redis, no Node build step.

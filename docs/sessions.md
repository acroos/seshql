# Sessions browser

`/sessions` is the entry point for reading individual Claude Code transcripts.

## Index page

The index lists every ingested session, newest first, with:

- **Title** — `custom_title` if Claude Code set one, otherwise the opening of
  the session's first user prompt.
- **Project** — the directory the session was started in, plus git branch,
  worktree, and agent name when present.
- **Cost** — estimated USD at Claude API list prices, shown top-right.
- **Duration** — time Claude actually spent working (summed `turn_duration`
  events) and the wall-clock span from first to last message. The two diverge
  sharply for sessions you resumed hours or days later.
- **Volume** — prompts you sent, turns Claude took, total tokens, and output
  tokens. Hover the token figure for the fresh/cache-write/cache-read/output
  split.
- **Output** — files edited, git commits, and linked PRs.

These all read from columns cached on `sessions` at ingest, so the index is a
single query regardless of session size.

### Filters

- **Search box** — substring match against the title, last prompt, and
  project path.
- **Project filter** — narrow to a single project directory or repo.

The index is paginated; URL params survive paging so you can share a
filtered link.

## Session detail

Click a row to land on `/sessions/:id`. You'll see:

- **Header** — session ID, agent name, permission mode, and a stat row of
  cost, active time, wall-clock span, your prompts, Claude's turns, and tokens.
- **Cost breakdown** — spend split across fresh input, 5-minute and 1-hour
  cache writes, cache reads, output, and web searches, each with its share of
  the total. Cache reads usually dominate the token count while output
  dominates cost per token, so the split is more informative than either
  number alone.
- **Output** — files edited, git commits, and linked PRs.
- **Message timeline** — every message in order. Tool calls show name, input,
  and the matching tool result.

Costs are estimates from [list prices](https://platform.claude.com/docs/en/about-claude/pricing)
and do not account for negotiated discounts or subscription plans. Rates live
in [`Pricing`](../app/services/pricing.rb); after editing them, re-run
`bin/rails sessions:backfill_aggregates` to reprice stored sessions.

If a session is mid-ingestion, the page may be missing recent messages — wait
a few seconds and refresh, or check `/ingestion_runs`.

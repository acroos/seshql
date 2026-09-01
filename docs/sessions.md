# Sessions browser

`/sessions` is the entry point for reading individual agent transcripts,
whether Claude Code or Codex produced them.

## Index page

The index lists every ingested session, newest first, with:

- **Title** — `custom_title` if the agent set one, otherwise the opening of
  the session's first real user prompt (injected developer and system messages
  are skipped).
- **Project** — the directory the session was started in, plus which agent ran
  it, the git branch, worktree, and agent name when present.
- **Cost** — estimated USD at the relevant provider's list prices (Anthropic
  for Claude Code, OpenAI for Codex), shown top-right.
- **Duration** — time the agent actually spent working (summed `turn_duration`
  events; the Codex adapter derives these from `turn_complete`) and the wall-clock span from first to last message. The two diverge
  sharply for sessions you resumed hours or days later.
- **Volume** — prompts you sent, turns the agent took, total tokens, and output
  tokens. Hover the token figure for the fresh/cache-write/cache-read/output
  split.
- **Output** — files edited, git commits, and linked PRs.

These all read from columns cached on `sessions` at ingest, so the index is a
single query regardless of session size.

### Filters

- **Search box** — substring match against the title, last prompt, and
  session id.
- **Project filter** — narrow to a single working directory. Both agents record
  a real absolute path, so a directory's pill covers sessions from either.
- **Agent filter** — add `?source=claude_code` or `?source=codex` to the URL to
  see one agent at a time.

The index is paginated; URL params survive paging so you can share a
filtered link.

## Session detail

Click a row to land on `/sessions/:id`. You'll see:

- **Header** — session ID, agent name, permission mode, and a stat row of
  cost, active time, wall-clock span, your prompts, the agent's turns, and
  tokens.
- **Cost breakdown** — spend split into the categories the agent's provider
  actually bills. Claude Code sessions show fresh input, 5-minute and 1-hour
  cache writes, cache reads, output, and web searches; Codex sessions show
  fresh input, cache writes (always $0, since OpenAI doesn't bill them), cache
  reads, and output. Each line carries its share of the total. Cache reads usually dominate the token count while output
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

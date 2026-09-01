# Sessions browser

`/sessions` is the entry point for reading individual agent transcripts,
whether Claude Code or Codex produced them.

## Index page

The index lists every ingested session, newest first, with:

- **Title** — `custom_title` if the agent set one, otherwise the best prompt
  in the session, cleaned up. See [How a session gets its
  name](#how-a-session-gets-its-name) below.
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

- **Search box** — substring match against the title (so a custom title and a
  derived one are both searchable), the last prompt, and the session id.
- **Project filter** — narrow to a single working directory. Both agents record
  a real absolute path, so a directory's pill covers sessions from either.
- **Agent filter** — add `?source=claude_code` or `?source=codex` to the URL to
  see one agent at a time.

The index is paginated; URL params survive paging so you can share a
filtered link.

## How a session gets its name

Sessions have no name of their own, so one is derived. `sessions.title` is a
generated column that takes the first of:

1. `custom_title`, when the agent set one.
2. `title_prompt` — the session's most title-worthy prompt, cleaned up.
3. The last prompt, cleaned up the same way.
4. `Session <first 8 of the id>`, for a session with nothing said in it.

Steps 2 and 3 are the interesting ones, because the obvious rule — "use the
first prompt" — produces bad names often. Claude Code stores several things in
the same slot as a typed prompt: slash-command invocations, `!` shell
commands, the output of both, and hook output. A session opened with `/clear`
used to be called `<command-name>/clear</command-name> <command-message>clear`,
truncated mid-tag.

Three Postgres functions handle it, all of them callable from the SQL Console:

- **`prompt_title(prompt)`** turns one prompt into displayable text, or `NULL`
  when it was the harness talking rather than you. `/clear` becomes `/clear`;
  `/fix <request>` becomes `/fix — <request>`; `!git status` becomes
  `$ git status`; command stdout, hook output, and system reminders become
  `NULL`. Prose is passed through with its newlines collapsed.
- **`prompt_title_rank(prompt)`** scores that output, lowest first: a stated
  request (prose, or a slash command carrying one) beats a bare acknowledgement
  like `ok`, which beats a shell command, which beats a bare `/clear` or
  `/model`. Harness output scores 99 and is excluded.
- **`title_snippet(body, max_length)`** truncates on a word boundary.

`Sessions::Ingester` orders a session's non-meta, non-sidechain prompts by rank
and then by time, and caches the winner as `title_prompt`. Ranking before time
is what fixes the common case: the `/clear` that opened the session loses to
the first real request behind it, however far in that was. Ordering by time
within a rank is what keeps the name about how the session *started* rather
than how it ended.

The heuristic is deliberately conservative — it never invents words, so a
session's name is always something that was actually said in it. A session
whose only content is `/login` really is called `/login`.

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

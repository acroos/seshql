# Sessions browser

`/sessions` is the entry point for reading individual Claude Code transcripts.

## Index page

The index lists every ingested session, newest first, with:

- **Title** — `custom_title` if Claude Code set one, otherwise the first 60
  characters of the session's last user prompt.
- **Project** — the directory the session was started in (resolved to a repo
  when one is linked).
- **Stats** — total messages, total tokens, duration.

### Filters

- **Search box** — substring match against the title, last prompt, and
  project path.
- **Project filter** — narrow to a single project directory or repo.

The index is paginated; URL params survive paging so you can share a
filtered link.

## Session detail

Click a row to land on `/sessions/:id`. You'll see:

- **Header** — session ID, agent name, permission mode, total tokens, total
  duration, linked PRs and repo.
- **Message timeline** — every message in order. User prompts and assistant
  responses render as Markdown; tool calls show name, input JSON, and the
  matching tool result.
- **Token panel** — input, output, cache-write, and cache-read tokens per
  assistant turn so you can see where the cost went.

If a session is mid-ingestion, the page may be missing recent messages — wait
a few seconds and refresh, or check `/ingestion_runs`.

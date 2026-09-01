# Ingestion

SeshQL reads the transcripts each coding agent leaves on disk and normalizes
them into one schema. Two agents are supported today:

| Agent | Where its transcripts live | One session is |
| --- | --- | --- |
| Claude Code | `$CLAUDE_HOME/projects/<encoded-path>/<uuid>.jsonl` | exactly one file |
| Codex | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread>.jsonl[.zst]` | one or more files |

`CLAUDE_HOME` defaults to `~/.claude` and `CODEX_HOME` to `~/.codex`. An agent
whose directory doesn't exist is skipped, so you never have to tell SeshQL
which agents you use.

## How files reach the database

Three triggers all funnel into the same code path
(`Sessions::Ingester.call(file_path)` → `IngestSessionFileJob` → upserted rows):

1. **Boot sweep.** When the Rails server starts, an initializer enqueues a
   `SessionsSweepJob` that scans every agent's session directory.
   Set `AUTO_INGEST=false` to skip it.
2. **File watcher.** `bin/watch` (started by `bin/dev`) listens for new and
   modified transcripts under every agent root and enqueues an
   `IngestSessionFileJob` per change. This is what gives you the "live as the
   agent runs" behavior.
3. **Recurring sweep.** `config/recurring.yml` runs `SessionsSweepJob` every
   5 minutes as a backstop in case the watcher missed a file.

The sweep tracks each file's mtime and size in `session_files`, so re-runs only
touch files that actually changed. Claude Code transcripts are also resumed
from a byte offset; Codex rollouts are always re-read in full (see below).

## Manual ingestion

```bash
bin/rails sessions:ingest        # run one sweep now (foreground)
bin/rails sessions:reingest      # delete every session row, then sweep
bin/rails sessions:backfill_aggregates  # recompute costs + cached stats in place
```

Use `reingest` after schema changes or if you want to rebuild from scratch.
It only clears SeshQL's tables — the underlying transcripts are untouched.

## What gets extracted

Both agents produce the same rows. What differs is how much work it takes to
get there.

| Row | From Claude Code | From Codex |
| --- | --- | --- |
| `user_prompts` | `user` line with string content | `response_item` `message`, classified by content kind |
| `assistant_messages` | `assistant` line | a run of assistant `response_item`s, grouped |
| `content_blocks` | the message's `content` array | one block per response item in the run |
| `tool_results` | `user` line with array content | `function_call_output` |
| `system_events` | `system` lines | `turn`/`task_complete`, `turn_aborted`, `compacted` |
| `pr_links` | `pr-link` lines | not emitted by Codex |
| `file_history_snapshots` | `file-history-snapshot` lines | not emitted by Codex |

### What the Codex adapter has to reconstruct

Codex rollout lines carry none of the identity Claude Code writes inline, so
`Sessions::Adapters::Codex` rebuilds three things:

- **Message identity.** Nothing in a rollout has a UUID. Each row gets a
  deterministic UUIDv5 derived from the thread id and the line's `ordinal`,
  which is what makes re-reading a file idempotent.
- **The model.** There is no per-message model. It is carried forward from the
  most recent `turn_context` line.
- **Token usage.** Usage never rides on the message. Depending on the Codex
  build it arrives either as `token_usage_record` lines keyed by turn, or as
  `token_count` events carrying `info.last_token_usage`. Both are read, and a
  transcript with both prefers the dedicated records so nothing is counted
  twice. The Nth assistant message in a turn takes the Nth usage reading; any
  readings unclaimed when the turn ends are folded into its last message so
  session totals stay whole.
- **Who actually typed a message.** See below.

Two consequences worth knowing when you query:

- **Codex files are never resumed from an offset.** A usage record can trail
  the message it belongs to, so a partial read would misattribute cost. Full
  re-reads are cheap and the upserts make them safe.
- **Codex reports `input_tokens` inclusive of cached tokens**, Anthropic
  reports them separately. The adapter subtracts, so
  `assistant_messages.input_tokens` means the same thing for both agents.

### Injected context vs. what you typed

Codex sends a lot of context as chat messages: skills instructions and
collaboration-mode prompts with role `developer`, and — importantly —
**AGENTS.md and the environment context with role `user`**. Trusting the role
would make a repository's instruction file look like the opening prompt, which
is exactly what it becomes in the session title.

So the role is not what decides. Each message carries
`internal_chat_message_metadata_passthrough.content_item_kinds`, one harness
classification per entry in its `content` array. Anything classified `user.*`
(`user.text`, `user.image`, `user.audio`) is the operator; everything else
(`agents_md.instructions`, `environments.environment_context`,
`host_skills.instructions`, `multi_agent.mode_instructions`, ...) is injected.
`ContentItemKind` is an open string rather than a fixed enum, so the adapter
matches the `user.` prefix instead of enumerating the injected kinds, and new
ones classify correctly without a change here.

Injected messages are still stored, marked `is_meta`, so nothing is lost and
they stay queryable. They are excluded from `user_message_count` and
`first_prompt`, and the session page renders them collapsed rather than as
something you said. When a message mixes both, only the `user.*` entries
become the prompt text.

Rollouts predating the classification fall back to the role.

### Code Mode

Codex can run in Code Mode, where it stops calling `shell` and `apply_patch`
directly and instead calls one `exec` tool whose input is a JavaScript program:

```js
const r = await tools.exec_command({"cmd": "git status", "workdir": "/repo"});
const patch = "*** Begin Patch\n*** Add File: README.md\n+hi\n*** End Patch";
await tools.apply_patch(patch);
```

Stored as-is, that leaves `tool_kind`, `bash_command`, `bash_programs`, and
`files_edited_count` empty for a session where the agent did plenty of both. So
the adapter reads the program: it collects the `tools.<name>(...)` calls,
lifts each `exec_command` `cmd` into `tool_input["command"]` and each patched
path into `tool_input["file_path"]`, and sets `tool_kind` from what the program
actually did. The columns then behave the way they do for Claude Code.

Two things to know:

- The whole program is kept under `tool_input["program"]`, so the extraction
  never loses anything, and `tool_input["tools"]` lists the underlying tools.
- A program running several commands has them joined with `; ` into one
  `bash_command`, and a program that both edits and runs commands is filed
  under `edit`, since a patched path is the harder signal to recover later.

### Turn events changed name

Codex 0.151 writes `task_started` / `task_complete`; newer builds write
`turn_started` / `turn_complete`. Both are accepted, and `duration_ms` from
either becomes the `turn_duration` system event that feeds
`active_duration_ms`.

### Duplicate content in Codex rollouts

A Codex thread in the default "legacy" history mode writes the same content
twice — once as a `response_item` and again as an `event_msg`. Only
`response_item` lines are read for content, so nothing is double-counted in
either history mode.

### Compressed rollouts

Codex compresses older rollouts to `.jsonl.zst`. SeshQL reads them by shelling
out to `zstd -dc`, which keeps a native decompression library out of the
dependency list. If `zstd` isn't on `PATH`, those files fail ingestion with a
clear message on `/ingestion_runs` and everything else keeps working.

## Cross-cutting tables

- **`pr_links`** — when a Claude Code message references a PR URL, an
  `EnrichPrLinkJob` runs `gh pr view` to fill in the title and repo.
- **`file_history_snapshots`** — Claude Code's periodic file snapshots are
  preserved so you can ask "what files were tracked at this point?"
- **`repos`** — `ResolveRepoJob` reads `git remote -v` in the session's
  working directory and links the session to a repo row. This works the same
  for both agents, since both record a real directory.

## Adding an agent

Everything agent-specific lives in one class under
`app/services/sessions/adapters/`. To add a third agent, subclass
`Sessions::Adapters::Base` and implement:

- `source` / `label` — the value stored in `sessions.source` and its UI name.
- `roots` — the directories the agent writes to. Missing ones mean "not
  installed" rather than an error.
- `session_id_for(path)` — derived from the path alone, so sweeps and the
  watcher can route a file without opening it.
- `parse(records)` — push normalized rows onto a `ParsedTranscript`.

Optionally override `file_patterns`, `transcript?`, `resumable?`, and
`each_record` (for a container format), plus `tool_kind` to map the agent's
tool names onto the shared kinds. Then add the class to
`Sessions::Adapters.all` and the value to the `session_source` enum.

`Sessions::Ingester` needs no changes.

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
  `[watch]`, `[sweep]`, or `IngestSessionFileJob`.

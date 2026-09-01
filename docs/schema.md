# Schema reference

Tables you can query from the SQL Console. Same data the in-app schema panel
shows; mirrored here for convenience. The authoritative source is
`SCHEMA_REFERENCE` in
[`app/controllers/sql_console_controller.rb`](../app/controllers/sql_console_controller.rb).

## Core tables

### `sessions`
One row per agent session, whichever agent produced it.

Identity and naming:
`session_id`, `source`, `source_metadata`, `title`, `custom_title`,
`title_prompt`, `first_prompt`, `last_prompt`, `agent_name`, `permission_mode`,
`project_path`, `directory`, `worktree`, `branch`, `worktree_config`,
`repo_id`, `created_at`, `ended_at`, `updated_at`

`title` is generated from `custom_title`, then `title_prompt`, then the last
prompt, then a short id. `title_prompt` is the session's most title-worthy
prompt, cleaned for display — usually but not always the first one, since a
session opened with `/clear` has its subject further in. `first_prompt` stays
literal: the first non-meta prompt, verbatim. See [how a session gets its
name](sessions.md#how-a-session-gets-its-name) for the functions involved.

`source` is `claude_code` or `codex` — filter on it to compare agents, or
group by it to see the split. `directory` is the absolute working directory
for both agents and is the column to group by when you want "per project";
`project_path` is the agent's own encoding of it and is mostly of interest for
Claude Code. `source_metadata` is JSONB holding agent-specific facts with no
column of their own (Codex's originator, CLI version, and git remote).

Aggregates, recomputed at ingest by `Sessions::Ingester`:
`total_input_tokens`, `total_output_tokens`, `total_cache_creation_tokens`,
`total_cache_read_tokens`, `total_cost_usd`, `user_message_count`,
`assistant_message_count`, `active_duration_ms`, `tools_used`,
`pr_link_count`, `files_edited_count`, `git_commit_count`

`total_input_tokens` is the sum of fresh input, cache writes, and cache reads;
subtract the two cache columns to get the genuinely new input. `total_cost_usd`
sums `assistant_messages.cost_usd`. `active_duration_ms` is the sum of
`turn_duration` system events — for wall-clock elapsed time use
`ended_at - created_at`, which is much larger for resumed sessions.

### `messages`
One row per transcript event. The polymorphic parent for the detail tables
below.

Codex rollouts carry no message ids, so their `uuid` is a deterministic
UUIDv5 derived from the thread and the line's ordinal; `parent_uuid`,
`is_sidechain`, `slug`, and `entrypoint` are Claude Code-only and are `NULL`
for Codex rows.

`uuid`, `session_id`, `parent_uuid`, `message_type`, `is_sidechain`,
`timestamp`, `cwd`, `git_branch`, `version`, `entrypoint`, `slug`, `user_type`

## Message details

Each detail row is keyed by `message_uuid` (joins to `messages.uuid`).

### `user_prompts`
`message_uuid`, `content_text`, `prompt_id`, `permission_mode`, `is_meta`

`is_meta` marks context the harness injected rather than something the operator
typed. It matters more for Codex than for Claude Code, because Codex sends
AGENTS.md and the environment context with role `user`; the adapter classifies
by the harness's own `content_item_kinds`, not by role. Filter
`is_meta = false` for anything meant to count real prompts.

### `assistant_messages`
`message_uuid`, `model`, `api_message_id`, `request_id`, `stop_reason`,
`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `cost_usd`, `usage_details`

Total tokens for an assistant turn:
`input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

`input_tokens` is always the *fresh* input for both agents — the tokens that
were neither read from nor written to the cache. Codex reports its
`input_tokens` inclusive of the cached portion, and the adapter subtracts it on
the way in, so the column means the same thing regardless of `source`.

`cost_usd` is the turn's estimated cost in USD, computed at ingest by
[`Pricing`](../app/services/pricing.rb), which dispatches to a per-provider
rate table: Anthropic bills 5-minute and 1-hour cache writes at different
multiples and adds surcharges for fast mode, US-pinned inference, and server
web search, while OpenAI does not bill cache writes at all and discounts cached
reads at a per-model rate. It is `NULL` for turns on a model with no known rate
(including Claude Code's synthetic error messages), so filter with
`IS NOT NULL` before summing if that matters.

### `content_blocks`
One row per block inside an assistant message (text, tool_use, thinking).
Joins to `assistant_messages` via `assistant_message_uuid`.

`id`, `assistant_message_uuid`, `position`, `block_type`, `text_content`,
`tool_use_id`, `tool_name`, `tool_kind`, `tool_input`, `bash_command`,
`bash_programs`, `thinking_signature`

`tool_input` is JSONB — query with `->`, `->>`, `?`, etc.

`tool_name` is whatever the agent called the tool (`Bash` for Claude Code,
`shell` for Codex). `tool_kind` is the normalized classification both map
onto, and is what you want in any query meant to span agents:

| `tool_kind` | Claude Code | Codex |
| --- | --- | --- |
| `shell` | `Bash`, `BashOutput`, `KillShell` | `shell`, `local_shell`, `exec_command` |
| `edit` | `Edit`, `Write`, `NotebookEdit` | `apply_patch`, `write_file` |
| `read` | `Read` | `read_file`, `view_image` |
| `search` | `Grep`, `Glob` | `grep`, `file_search`, `tool_search` |
| `plan` | `TodoWrite`, `ExitPlanMode` | `update_plan` |
| `agent` | `Task`, `TaskCreate`, `TaskUpdate`, `Skill` | — |
| `user_input` | `AskUserQuestion`, `SendUserFile` | — |
| `web_search` / `web_fetch` | `WebSearch`, `WebFetch` | `web_search` |
| `mcp` | any `mcp__*` tool | any `mcp__*` tool |
| `code_mode` | — | an `exec` program calling nothing recognized |

`bash_command` and `bash_programs` are generated columns, populated for every
`tool_kind = 'shell'` block regardless of agent. Codex passes its commands as
an argv array (`["bash", "-lc", "git status"]`); the `shell_command()` SQL
function unwraps that to the same string Claude Code stores, so
`WHERE bash_command LIKE 'git %'` matches both agents. `bash_programs` is the
GIN-indexed list of programs invoked.

### `tool_results`
`message_uuid`, `tool_use_id`, `source_assistant_uuid`, `result_type`,
`result_content`

### `system_events`
`message_uuid`, `subtype`, `duration_ms`, `message_count`, `hook_count`,
`prevented_continuation`, `stop_reason`, `has_output`, `level`, `is_meta`,
`hook_infos`, `hook_errors`

`subtype = 'turn_duration'` rows carry `duration_ms` for per-turn timing.

### `attachments`
`message_uuid`, `attachment_type`, `attachment_data`

## Cross-cutting tables

### `pr_links`
Links a session to a GitHub PR. Only Claude Code records these. Title and repo are filled in asynchronously
by `EnrichPrLinkJob` via `gh pr view`.

`id`, `session_id`, `pr_number`, `pr_url`, `pr_repository`, `linked_at`

### `session_files`
One row per transcript file on disk, with how far ingestion has read it.
Separate from `sessions` because the relationship is not one-to-one: a
reverted Codex thread keeps its id but starts a new rollout file, so one
session can be assembled from several files.

`id`, `file_path`, `session_id`, `source`, `file_mtime`, `file_size`,
`last_byte_offset`, `last_ingested_at`

### `file_history_snapshots`
Periodic snapshots of which files Claude Code was tracking. Not emitted by
Codex.

`id`, `session_id`, `source_message_id`, `is_snapshot_update`,
`tracked_files`, `snapshot_timestamp`

## Common joins

The query that backs most token analyses:

```sql
FROM sessions s
JOIN messages m            ON m.session_id = s.session_id
JOIN assistant_messages am ON am.message_uuid = m.uuid
JOIN content_blocks cb     ON cb.assistant_message_uuid = am.message_uuid
```

For tool inputs, filter on `cb.block_type = 'tool_use'` and either
`cb.tool_kind = '<kind>'` (spans agents) or `cb.tool_name = '<name>'` (one
agent's own name). For per-turn timing, join `system_events` on `message_uuid`
with `subtype = 'turn_duration'` — the Codex adapter writes that same subtype
from `turn_complete`, so timing queries need no special-casing.

To compare agents, group by `s.source`:

```sql
SELECT s.source,
       COUNT(*)                    AS sessions,
       ROUND(SUM(s.total_cost_usd), 2) AS cost,
       ROUND(AVG(s.active_duration_ms) / 60000.0, 1) AS avg_active_minutes
FROM sessions s
GROUP BY s.source
```

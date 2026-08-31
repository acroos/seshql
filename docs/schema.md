# Schema reference

Tables you can query from the SQL Console. Same data the in-app schema panel
shows; mirrored here for convenience. The authoritative source is
`SCHEMA_REFERENCE` in
[`app/controllers/sql_console_controller.rb`](../app/controllers/sql_console_controller.rb).

## Core tables

### `sessions`
One row per Claude Code session (one JSONL file).

Identity and naming:
`session_id`, `title`, `custom_title`, `first_prompt`, `last_prompt`,
`agent_name`, `permission_mode`, `project_path`, `directory`, `worktree`,
`branch`, `worktree_config`, `repo_id`, `created_at`, `ended_at`, `updated_at`

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
One row per JSONL line. The polymorphic parent for the detail tables below.

`uuid`, `session_id`, `parent_uuid`, `message_type`, `is_sidechain`,
`timestamp`, `cwd`, `git_branch`, `version`, `entrypoint`, `slug`, `user_type`

## Message details

Each detail row is keyed by `message_uuid` (joins to `messages.uuid`).

### `user_prompts`
`message_uuid`, `content_text`, `prompt_id`, `permission_mode`, `is_meta`

### `assistant_messages`
`message_uuid`, `model`, `api_message_id`, `request_id`, `stop_reason`,
`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `cost_usd`, `usage_details`

Total tokens for an assistant turn:
`input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

`cost_usd` is the turn's estimated cost in USD, computed at ingest by
[`Pricing`](../app/services/pricing.rb) from the model's list rates and the
turn's cache-write duration, fast mode, and inference geography. It is `NULL`
for turns on a model with no known rate (including Claude Code's synthetic
error messages), so filter with `IS NOT NULL` before summing if that matters.

### `content_blocks`
One row per block inside an assistant message (text, tool_use, thinking).
Joins to `assistant_messages` via `assistant_message_uuid`.

`id`, `assistant_message_uuid`, `position`, `block_type`, `text_content`,
`tool_use_id`, `tool_name`, `tool_input`, `thinking_signature`

`tool_input` is JSONB — query with `->`, `->>`, `?`, etc.

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
Links a session to a GitHub PR. Title and repo are filled in asynchronously
by `EnrichPrLinkJob` via `gh pr view`.

`id`, `session_id`, `pr_number`, `pr_url`, `pr_repository`, `linked_at`

### `file_history_snapshots`
Periodic snapshots of which files Claude Code was tracking.

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

For tool inputs, filter on `cb.block_type = 'tool_use'` and
`cb.tool_name = '<name>'`. For per-turn timing, join `system_events` on
`message_uuid` with `subtype = 'turn_duration'`.

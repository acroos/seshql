# Schema reference

Tables you can query from the SQL Console. Same data the in-app schema panel
shows; mirrored here for convenience. The authoritative source is
`SCHEMA_REFERENCE` in
[`app/controllers/sql_console_controller.rb`](../app/controllers/sql_console_controller.rb).

## Core tables

### `sessions`
One row per Claude Code session (one JSONL file).

`session_id`, `permission_mode`, `custom_title`, `agent_name`, `last_prompt`,
`project_path`, `worktree_config`, `created_at`, `updated_at`

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
`cache_read_input_tokens`, `usage_details`

Total tokens for an assistant turn:
`input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

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

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_01_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"


  create_function :shell_command, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.shell_command(input jsonb)
       RETURNS text
       LANGUAGE sql
       IMMUTABLE PARALLEL SAFE
      AS $function$
        SELECT CASE jsonb_typeof(input->'command')
          WHEN 'string' THEN input->>'command'
          WHEN 'array' THEN
            CASE
              WHEN jsonb_array_length(input->'command') = 3
               AND (input->'command'->>0) ~ '(^|/)(ba|z|k|da)?sh$'
               AND (input->'command'->>1) ~ '^-[a-z]*c[a-z]*$'
              THEN input->'command'->>2
              ELSE (
                SELECT string_agg(value, ' ' ORDER BY ordinality)
                FROM jsonb_array_elements_text(input->'command')
                  WITH ORDINALITY AS t(value, ordinality)
              )
            END
        END;
      $function$
  SQL

  create_function :bash_programs, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.bash_programs(cmd text)
       RETURNS text[]
       LANGUAGE sql
       IMMUTABLE PARALLEL SAFE
      AS $function$
        SELECT array_agg(prog)
        FROM (
          SELECT (regexp_match(
            segment,
            '^\s*(?:\w+=\S+\s+)*([\w./-]+)'
          ))[1] AS prog
          FROM regexp_split_to_table(cmd, '\s*(?:&&|\|\||;|\|)\s*') AS segment
        ) s
        WHERE prog ~ '[A-Za-z]'
          AND prog NOT IN ('if','then','else','elif','fi','for','while','until','do','done','case','esac','in','end','function','select');
      $function$
  SQL

  create_function :prompt_title, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.prompt_title(prompt text)
       RETURNS text
       LANGUAGE sql
       IMMUTABLE PARALLEL SAFE
      AS $function$
        WITH stripped AS (
          -- A system reminder is appended to whatever the operator typed. It is
          -- never part of what they meant to say, so it never reaches the title.
          SELECT btrim(regexp_replace(COALESCE(prompt, ''),
                                      '<system-reminder>.*?</system-reminder>', ' ', 'gs')) AS body
        ), parts AS (
          SELECT
            body,
            -- The three command tags arrive in no fixed order -- `/ui-ux-pro-max`
            -- leads with `<command-message>`, `/clear` with `<command-name>` -- so
            -- each is matched on its own rather than as one anchored pattern.
            btrim(COALESCE((regexp_match(body, '<command-name>\s*/?(.*?)</command-name>', 's'))[1], '')) AS command,
            btrim(COALESCE((regexp_match(body, '<command-args>(.*?)</command-args>', 's'))[1], '')) AS args,
            btrim(COALESCE((regexp_match(body, '<bash-input>(.*?)</bash-input>', 's'))[1], '')) AS shell
          FROM stripped
        )
        SELECT NULLIF(btrim(regexp_replace(
          CASE
            WHEN body = '' THEN ''
            -- Output, not input. Never a name.
            WHEN body ~ '^<(local-command-(stdout|stderr|caveat)|bash-(stdout|stderr)|task-notification|user-prompt-submit-hook|ide_[a-z_]+)>'
              THEN ''
            -- `/skill some request` carries the request in its args; that is the
            -- interesting half, but the command name says which lens it ran under.
            WHEN body ~ '^<command-' AND command <> '' AND args <> ''
              THEN '/' || command || ' — ' || args
            WHEN body ~ '^<command-' AND command <> ''
              THEN '/' || command
            WHEN body ~ '^<bash-input>' AND shell <> ''
              THEN '$ ' || shell
            -- Prose, with newlines collapsed so a multi-line prompt still renders
            -- as a single line.
            ELSE body
          END, '\s+', ' ', 'g')), '')
        FROM parts;
      $function$
  SQL

  create_function :prompt_title_rank, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.prompt_title_rank(prompt text)
       RETURNS integer
       LANGUAGE sql
       IMMUTABLE PARALLEL SAFE
      AS $function$
        SELECT CASE
          WHEN title IS NULL THEN 99  -- harness output; never a name
          -- A stated request, whether typed plainly or handed to a slash command.
          -- `/ui-ux-pro-max — redesign this leaderboard` says as much as prose does,
          -- so it competes on time rather than losing to every later sentence.
          WHEN title LIKE '/%' AND title LIKE '% — %' THEN 0
          WHEN title NOT LIKE '/%' AND title NOT LIKE '$ %' AND char_length(title) >= 12 THEN 0
          WHEN title NOT LIKE '/%' AND title NOT LIKE '$ %' THEN 1  -- "ok", "yes", "ship it"
          WHEN title LIKE '$ %' THEN 2                              -- a ! shell command
          ELSE 3                                                    -- bare /clear, /model, /login
        END
        FROM (SELECT prompt_title(prompt) AS title) t;
      $function$
  SQL

  create_function :title_snippet, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.title_snippet(body text, max_length integer)
       RETURNS text
       LANGUAGE sql
       IMMUTABLE PARALLEL SAFE
      AS $function$
        SELECT CASE
          WHEN body IS NULL OR char_length(body) <= max_length THEN body
          ELSE left(
                 -- Drop back to the last whole word. A first word that already
                 -- fills the budget has no boundary to find, so it is cut instead.
                 COALESCE(NULLIF(regexp_replace(left(body, max_length + 1), '\s+\S*$', ''), ''), body),
                 max_length
               ) || '…'
        END;
      $function$
  SQL
  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "block_type", ["thinking", "text", "tool_use"]
  create_enum "message_type", ["user_prompt", "tool_result", "assistant", "system", "attachment"]
  create_enum "session_source", ["claude_code", "codex"]

  create_table "assistant_messages", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.string "api_message_id"
    t.integer "cache_creation_input_tokens", default: 0
    t.integer "cache_read_input_tokens", default: 0
    t.decimal "cost_usd", precision: 12, scale: 6
    t.integer "input_tokens", default: 0
    t.string "model"
    t.integer "output_tokens", default: 0
    t.string "request_id"
    t.string "stop_reason"
    t.jsonb "usage_details", default: {}
    t.index ["api_message_id"], name: "index_assistant_messages_on_api_message_id"
    t.index ["model"], name: "index_assistant_messages_on_model"
  end

  create_table "attachments", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.jsonb "attachment_data", default: {}
    t.string "attachment_type"
    t.index ["attachment_type"], name: "index_attachments_on_attachment_type"
  end

  create_table "content_blocks", force: :cascade do |t|
    t.uuid "assistant_message_uuid", null: false
    t.virtual "bash_command", type: :text, as: "\nCASE\n    WHEN ((tool_kind)::text = 'shell'::text) THEN shell_command(tool_input)\n    ELSE NULL::text\nEND", stored: true
    t.virtual "bash_programs", type: :text, array: true, as: "\nCASE\n    WHEN ((tool_kind)::text = 'shell'::text) THEN bash_programs(shell_command(tool_input))\n    ELSE NULL::text[]\nEND", stored: true
    t.enum "block_type", null: false, enum_type: "block_type"
    t.integer "position", null: false
    t.text "text_content"
    t.text "thinking_signature"
    t.jsonb "tool_input", default: {}
    t.string "tool_kind"
    t.string "tool_name"
    t.string "tool_use_id"
    t.index ["assistant_message_uuid", "position"], name: "uniq_content_blocks_on_assistant_position", unique: true
    t.index ["assistant_message_uuid"], name: "index_content_blocks_on_assistant_message_uuid"
    t.index ["bash_programs"], name: "index_content_blocks_on_bash_programs", using: :gin
    t.index ["block_type"], name: "index_content_blocks_on_block_type"
    t.index ["tool_kind"], name: "index_content_blocks_on_tool_kind"
    t.index ["tool_name"], name: "index_content_blocks_on_tool_name"
  end

  create_table "dashboard_panels", force: :cascade do |t|
    t.string "chart_type", default: "bar", null: false
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.bigint "dashboard_id", null: false
    t.integer "position", default: 0, null: false
    t.string "series_column"
    t.text "sql_query", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "value_column"
    t.string "x_column"
    t.index ["dashboard_id"], name: "index_dashboard_panels_on_dashboard_id"
  end

  create_table "dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "file_history_snapshots", force: :cascade do |t|
    t.boolean "is_snapshot_update", default: false
    t.string "session_id", null: false
    t.datetime "snapshot_timestamp"
    t.string "source_message_id", null: false
    t.jsonb "tracked_files", default: {}
    t.index ["session_id", "source_message_id"], name: "uniq_file_history_on_session_source", unique: true
    t.index ["session_id"], name: "index_file_history_snapshots_on_session_id"
    t.index ["source_message_id"], name: "index_file_history_snapshots_on_source_message_id"
  end

  create_table "ingestion_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "error_class"
    t.text "error_message"
    t.string "file_path", null: false
    t.integer "lines_processed"
    t.datetime "run_at", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["file_path", "run_at"], name: "index_ingestion_runs_on_file_path_and_run_at"
    t.index ["run_at"], name: "index_ingestion_runs_on_run_at"
    t.index ["status"], name: "index_ingestion_runs_on_status"
  end

  create_table "messages", primary_key: "uuid", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cwd"
    t.string "entrypoint"
    t.string "git_branch"
    t.boolean "is_sidechain", default: false
    t.enum "message_type", null: false, enum_type: "message_type"
    t.uuid "parent_uuid"
    t.string "session_id", null: false
    t.string "slug"
    t.datetime "timestamp"
    t.string "user_type"
    t.string "version"
    t.index ["message_type"], name: "index_messages_on_message_type"
    t.index ["parent_uuid"], name: "index_messages_on_parent_uuid"
    t.index ["session_id"], name: "index_messages_on_session_id"
    t.index ["timestamp"], name: "index_messages_on_timestamp"
  end

  create_table "pr_links", force: :cascade do |t|
    t.datetime "linked_at"
    t.integer "pr_number"
    t.string "pr_repository"
    t.string "pr_title"
    t.string "pr_url"
    t.string "session_id", null: false
    t.index ["pr_repository"], name: "index_pr_links_on_pr_repository"
    t.index ["session_id", "pr_repository", "pr_number"], name: "uniq_pr_links_on_session_repo_number", unique: true
    t.index ["session_id"], name: "index_pr_links_on_session_id"
  end

  create_table "repos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "filesystem_path"
    t.string "name", null: false
    t.string "remote_url"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_repos_on_name", unique: true
  end

  create_table "session_files", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "file_mtime"
    t.string "file_path", null: false
    t.bigint "file_size"
    t.bigint "last_byte_offset", default: 0, null: false
    t.datetime "last_ingested_at"
    t.string "session_id", null: false
    t.enum "source", null: false, enum_type: "session_source"
    t.datetime "updated_at", null: false
    t.index ["file_mtime"], name: "index_session_files_on_file_mtime"
    t.index ["file_path"], name: "index_session_files_on_file_path", unique: true
    t.index ["session_id"], name: "index_session_files_on_session_id"
  end

  create_table "sessions", primary_key: "session_id", id: :string, force: :cascade do |t|
    t.bigint "active_duration_ms", default: 0, null: false
    t.string "agent_name"
    t.integer "assistant_message_count", default: 0, null: false
    t.string "branch"
    t.datetime "created_at", null: false
    t.string "custom_title"
    t.text "directory"
    t.datetime "ended_at"
    t.integer "files_edited_count", default: 0, null: false
    t.text "first_prompt"
    t.integer "git_commit_count", default: 0, null: false
    t.text "last_prompt"
    t.string "permission_mode"
    t.integer "pr_link_count", default: 0, null: false
    t.string "project_path"
    t.bigint "repo_id"
    t.enum "source", default: "claude_code", null: false, enum_type: "session_source"
    t.jsonb "source_metadata", default: {}, null: false
    t.virtual "title", type: :text, as: "COALESCE(NULLIF(btrim((custom_title)::text), ''::text), title_snippet(title_prompt, 90), title_snippet(prompt_title(last_prompt), 90), ('Session '::text || \"left\"((session_id)::text, 8)))", stored: true
    t.text "title_prompt"
    t.string "tools_used", default: [], array: true
    t.bigint "total_cache_creation_tokens", default: 0, null: false
    t.bigint "total_cache_read_tokens", default: 0, null: false
    t.decimal "total_cost_usd", precision: 12, scale: 6
    t.bigint "total_input_tokens", default: 0, null: false
    t.bigint "total_output_tokens", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_message_count", default: 0, null: false
    t.text "worktree"
    t.jsonb "worktree_config", default: {}
    t.index ["active_duration_ms"], name: "index_sessions_on_active_duration_ms"
    t.index ["created_at"], name: "index_sessions_on_created_at"
    t.index ["directory"], name: "index_sessions_on_directory"
    t.index ["ended_at"], name: "index_sessions_on_ended_at"
    t.index ["project_path"], name: "index_sessions_on_project_path"
    t.index ["repo_id"], name: "index_sessions_on_repo_id"
    t.index ["source"], name: "index_sessions_on_source"
    t.index ["tools_used"], name: "index_sessions_on_tools_used", using: :gin
    t.index ["total_cost_usd"], name: "index_sessions_on_total_cost_usd"
    t.index ["worktree"], name: "index_sessions_on_worktree"
  end

  create_table "system_events", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.integer "duration_ms"
    t.boolean "has_output", default: false
    t.integer "hook_count"
    t.jsonb "hook_errors", default: []
    t.jsonb "hook_infos", default: []
    t.boolean "is_meta", default: false
    t.string "level"
    t.integer "message_count"
    t.boolean "prevented_continuation", default: false
    t.string "stop_reason"
    t.string "subtype", null: false
    t.index ["subtype"], name: "index_system_events_on_subtype"
  end

  create_table "tool_results", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.jsonb "result_content", default: {}
    t.string "result_type"
    t.uuid "source_assistant_uuid"
    t.string "tool_use_id"
    t.index ["source_assistant_uuid"], name: "index_tool_results_on_source_assistant_uuid"
    t.index ["tool_use_id"], name: "index_tool_results_on_tool_use_id"
  end

  create_table "user_prompts", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.text "content_text"
    t.boolean "is_meta", default: false
    t.string "permission_mode"
    t.string "prompt_id"
    t.index ["prompt_id"], name: "index_user_prompts_on_prompt_id"
  end

  add_foreign_key "assistant_messages", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "attachments", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "content_blocks", "assistant_messages", column: "assistant_message_uuid", primary_key: "message_uuid"
  add_foreign_key "dashboard_panels", "dashboards"
  add_foreign_key "file_history_snapshots", "sessions", primary_key: "session_id"
  add_foreign_key "messages", "sessions", primary_key: "session_id"
  add_foreign_key "pr_links", "sessions", primary_key: "session_id"
  add_foreign_key "session_files", "sessions", primary_key: "session_id", on_delete: :cascade
  add_foreign_key "sessions", "repos"
  add_foreign_key "system_events", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "tool_results", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "user_prompts", "messages", column: "message_uuid", primary_key: "uuid"
end

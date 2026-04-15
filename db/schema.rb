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

ActiveRecord::Schema[8.1].define(version: 2026_04_14_000014) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "block_type", ["thinking", "text", "tool_use"]
  create_enum "message_type", ["user_prompt", "tool_result", "assistant", "system", "attachment"]

  create_table "assistant_messages", primary_key: "message_uuid", id: :uuid, default: nil, force: :cascade do |t|
    t.string "api_message_id"
    t.integer "cache_creation_input_tokens", default: 0
    t.integer "cache_read_input_tokens", default: 0
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
    t.enum "block_type", null: false, enum_type: "block_type"
    t.integer "position", null: false
    t.text "text_content"
    t.text "thinking_signature"
    t.jsonb "tool_input", default: {}
    t.string "tool_name"
    t.string "tool_use_id"
    t.index ["assistant_message_uuid"], name: "index_content_blocks_on_assistant_message_uuid"
    t.index ["block_type"], name: "index_content_blocks_on_block_type"
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
    t.index ["session_id"], name: "index_file_history_snapshots_on_session_id"
    t.index ["source_message_id"], name: "index_file_history_snapshots_on_source_message_id"
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

  create_table "sessions", primary_key: "session_id", id: :string, force: :cascade do |t|
    t.string "agent_name"
    t.datetime "created_at", null: false
    t.string "custom_title"
    t.string "inferred_title"
    t.text "last_prompt"
    t.string "permission_mode"
    t.string "project_path"
    t.bigint "repo_id"
    t.datetime "updated_at", null: false
    t.jsonb "worktree_config", default: {}
    t.index ["created_at"], name: "index_sessions_on_created_at"
    t.index ["project_path"], name: "index_sessions_on_project_path"
    t.index ["repo_id"], name: "index_sessions_on_repo_id"
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
  add_foreign_key "sessions", "repos"
  add_foreign_key "system_events", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "tool_results", "messages", column: "message_uuid", primary_key: "uuid"
  add_foreign_key "user_prompts", "messages", column: "message_uuid", primary_key: "uuid"
end

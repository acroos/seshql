# Generalizes the schema from "Claude Code transcripts" to "agent session
# transcripts", so Codex rollouts can live alongside Claude Code sessions.
#
# Three structural changes:
#
#   1. `sessions.source` records which agent produced a session.
#   2. Ingest watermarks move off `sessions` into `session_files`. A Claude
#      session is always exactly one file, but a Codex thread that has been
#      reverted owns several rollout files, so the watermark cannot live on
#      the session row.
#   3. `directory` and `worktree` stop being generated columns derived from
#      Claude's encoded project path and become plain columns each adapter
#      fills in. Same for the shell-command columns, which now key off a
#      normalized `tool_kind` rather than the literal tool name "Bash".
class AddMultiSourceSupport < ActiveRecord::Migration[8.1]
  def up
    create_enum :session_source, %w[claude_code codex]

    add_column :sessions, :source, :enum, enum_type: :session_source,
               default: "claude_code", null: false
    add_index :sessions, :source

    # Agent-specific session facts that have no column of their own: Claude's
    # entrypoint, Codex's originator and history mode, and so on.
    add_column :sessions, :source_metadata, :jsonb, default: {}, null: false

    create_session_files
    replace_derived_session_columns
    add_tool_kind
  end

  def down
    restore_generated_session_columns
    remove_tool_kind
    drop_table :session_files
    restore_session_watermarks

    remove_column :sessions, :source_metadata if column_exists?(:sessions, :source_metadata)
    remove_index :sessions, :source
    remove_column :sessions, :source
    execute "DROP TYPE IF EXISTS session_source;"
  end

  private

  # One row per transcript file on disk. `session_id` is not unique: several
  # rollout files can project into a single Codex thread.
  def create_session_files
    create_table :session_files do |t|
      t.string :file_path, null: false
      t.string :session_id, null: false
      t.enum :source, enum_type: :session_source, null: false
      t.datetime :file_mtime
      t.bigint :file_size
      t.bigint :last_byte_offset, default: 0, null: false
      t.datetime :last_ingested_at
      t.timestamps

      t.index :file_path, unique: true
      t.index :session_id
      t.index :file_mtime
    end

    add_foreign_key :session_files, :sessions, primary_key: "session_id", on_delete: :cascade

    # Claude sessions are 1:1 with their file, so the existing watermarks move
    # across unchanged. The path is reconstructed from the project path.
    execute <<~SQL
      INSERT INTO session_files
        (file_path, session_id, source, file_mtime, file_size, last_byte_offset,
         last_ingested_at, created_at, updated_at)
      SELECT
        #{quote(claude_projects_dir)} || '/' || project_path || '/' || session_id || '.jsonl',
        session_id,
        'claude_code'::session_source,
        file_mtime,
        file_size,
        last_byte_offset,
        last_ingested_at,
        NOW(),
        NOW()
      FROM sessions
      WHERE project_path IS NOT NULL;
    SQL

    remove_index :sessions, :file_mtime
    remove_column :sessions, :file_mtime
    remove_column :sessions, :file_size
    remove_column :sessions, :last_byte_offset
    remove_column :sessions, :last_ingested_at
  end

  def restore_session_watermarks
    add_column :sessions, :file_mtime, :datetime
    add_column :sessions, :file_size, :bigint
    add_column :sessions, :last_byte_offset, :bigint, default: 0, null: false
    add_column :sessions, :last_ingested_at, :datetime
    add_index :sessions, :file_mtime
  end

  # `directory` and `worktree` were STORED generated columns that parsed
  # Claude's `-Users-me-dev-thing--claude-worktrees-branch` encoding. Postgres
  # cannot convert a generated column in place, so they are dropped and
  # re-added as plain columns, preserving the values already computed.
  def replace_derived_session_columns
    add_column :sessions, :new_directory, :text
    add_column :sessions, :new_worktree, :text
    execute "UPDATE sessions SET new_directory = directory, new_worktree = worktree;"

    remove_index :sessions, :worktree
    remove_column :sessions, :directory
    remove_column :sessions, :worktree

    rename_column :sessions, :new_directory, :directory
    rename_column :sessions, :new_worktree, :worktree
    add_index :sessions, :directory
    add_index :sessions, :worktree
  end

  def restore_generated_session_columns
    remove_index :sessions, :directory
    remove_index :sessions, :worktree
    remove_column :sessions, :directory
    remove_column :sessions, :worktree

    execute <<~SQL
      ALTER TABLE sessions
        ADD COLUMN directory text
        GENERATED ALWAYS AS (
          NULLIF(
            replace(
              regexp_replace(
                regexp_replace(project_path, '--claude-worktrees-.*$', ''),
                '^-', ''
              ),
              '-', '/'
            ),
            ''
          )
        ) STORED;
    SQL

    execute <<~SQL
      ALTER TABLE sessions
        ADD COLUMN worktree text
        GENERATED ALWAYS AS (
          NULLIF(split_part(project_path, '--claude-worktrees-', 2), '')
        ) STORED;
    SQL

    add_index :sessions, :worktree
  end

  # `tool_kind` is the cross-agent classification ("shell", "edit", "read", ...)
  # that Claude's `Bash`/`Edit` and Codex's `shell`/`apply_patch` both map onto.
  # `tool_name` keeps whatever the agent actually wrote.
  def add_tool_kind
    add_column :content_blocks, :tool_kind, :string
    add_index :content_blocks, :tool_kind
    execute <<~SQL
      UPDATE content_blocks SET tool_kind = CASE tool_name
        WHEN 'Bash' THEN 'shell'
        WHEN 'Edit' THEN 'edit'
        WHEN 'Write' THEN 'edit'
        WHEN 'NotebookEdit' THEN 'edit'
        WHEN 'Read' THEN 'read'
        WHEN 'Grep' THEN 'search'
        WHEN 'Glob' THEN 'search'
        WHEN 'WebSearch' THEN 'web_search'
        WHEN 'WebFetch' THEN 'web_fetch'
        WHEN 'Task' THEN 'agent'
        WHEN 'TodoWrite' THEN 'plan'
      END
      WHERE tool_name IS NOT NULL;
    SQL

    create_shell_command_function
    rebuild_shell_columns(keyed_on: "tool_kind = 'shell'",
                          command_expression: "shell_command(tool_input)")
  end

  def remove_tool_kind
    rebuild_shell_columns(keyed_on: "tool_name = 'Bash'",
                          command_expression: "tool_input->>'command'")
    execute "DROP FUNCTION IF EXISTS shell_command(jsonb);"
    remove_index :content_blocks, :tool_kind
    remove_column :content_blocks, :tool_kind
  end

  # Claude writes `{"command": "ls -al"}`; Codex writes
  # `{"command": ["bash", "-lc", "ls -al"]}`. Both reduce to one command string.
  # A `bash -lc <script>` wrapper contributes only the script, since the
  # wrapper is an artifact of how Codex shells out rather than a program the
  # session meaningfully ran.
  def create_shell_command_function
    execute <<~SQL
      CREATE OR REPLACE FUNCTION shell_command(input jsonb)
      RETURNS text
      LANGUAGE sql
      IMMUTABLE
      PARALLEL SAFE
      AS $$
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
      $$;
    SQL
  end

  def rebuild_shell_columns(keyed_on:, command_expression:)
    remove_index :content_blocks, :bash_programs
    remove_column :content_blocks, :bash_programs
    remove_column :content_blocks, :bash_command

    execute <<~SQL
      ALTER TABLE content_blocks
        ADD COLUMN bash_command text
        GENERATED ALWAYS AS (
          CASE WHEN #{keyed_on} THEN #{command_expression} END
        ) STORED;
    SQL

    execute <<~SQL
      ALTER TABLE content_blocks
        ADD COLUMN bash_programs text[]
        GENERATED ALWAYS AS (
          CASE WHEN #{keyed_on}
            THEN bash_programs(#{command_expression})
          END
        ) STORED;
    SQL

    add_index :content_blocks, :bash_programs, using: :gin
  end

  def claude_projects_dir
    File.expand_path("~/.claude/projects")
  end
end

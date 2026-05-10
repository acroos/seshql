class AddNamingAndAggregateColumnsToSessions < ActiveRecord::Migration[8.1]
  def up
    # Cached-at-ingest columns (regular columns, populated by Sessions::Ingester)
    add_column :sessions, :branch, :string
    add_column :sessions, :first_prompt, :text
    add_column :sessions, :ended_at, :datetime
    add_column :sessions, :total_input_tokens, :bigint, default: 0, null: false
    add_column :sessions, :total_output_tokens, :bigint, default: 0, null: false
    add_column :sessions, :tools_used, :string, array: true, default: []

    # Generated columns (pure functions of row-local data)
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

    execute <<~SQL
      ALTER TABLE sessions
        ADD COLUMN title text
        GENERATED ALWAYS AS (
          COALESCE(
            NULLIF(custom_title, ''),
            LEFT(NULLIF(first_prompt, ''), 80),
            LEFT(NULLIF(last_prompt, ''), 80),
            session_id
          )
        ) STORED;
    SQL

    add_index :sessions, :tools_used, using: :gin
    add_index :sessions, :worktree
    add_index :sessions, :ended_at
  end

  def down
    remove_index :sessions, :ended_at
    remove_index :sessions, :worktree
    remove_index :sessions, :tools_used

    remove_column :sessions, :title
    remove_column :sessions, :worktree
    remove_column :sessions, :directory

    remove_column :sessions, :tools_used
    remove_column :sessions, :total_output_tokens
    remove_column :sessions, :total_input_tokens
    remove_column :sessions, :ended_at
    remove_column :sessions, :first_prompt
    remove_column :sessions, :branch
  end
end

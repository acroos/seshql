class TightenBashProgramsFunction < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION bash_programs(cmd text)
      RETURNS text[]
      LANGUAGE sql
      IMMUTABLE
      PARALLEL SAFE
      AS $$
        SELECT array_agg(prog)
        FROM (
          SELECT (regexp_match(
            segment,
            '^\\s*(?:\\w+=\\S+\\s+)*([\\w./-]+)'
          ))[1] AS prog
          FROM regexp_split_to_table(cmd, '\\s*(?:&&|\\|\\||;|\\||\\n)\\s*') AS segment
        ) s
        WHERE prog ~ '[A-Za-z]';
      $$;
    SQL

    remove_index :content_blocks, :bash_programs
    remove_column :content_blocks, :bash_programs

    execute <<~SQL
      ALTER TABLE content_blocks
        ADD COLUMN bash_programs text[]
        GENERATED ALWAYS AS (
          CASE WHEN tool_name = 'Bash'
            THEN bash_programs(tool_input->>'command')
          END
        ) STORED;
    SQL

    add_index :content_blocks, :bash_programs, using: :gin
  end

  def down
    remove_index :content_blocks, :bash_programs
    remove_column :content_blocks, :bash_programs

    execute <<~SQL
      CREATE OR REPLACE FUNCTION bash_programs(cmd text)
      RETURNS text[]
      LANGUAGE sql
      IMMUTABLE
      PARALLEL SAFE
      AS $$
        SELECT array_agg(prog)
        FROM (
          SELECT (regexp_match(
            segment,
            '^\\s*(?:\\w+=\\S+\\s+)*([\\w./-]+)'
          ))[1] AS prog
          FROM regexp_split_to_table(cmd, '\\s*(?:&&|\\|\\||;|\\||\\n)\\s*') AS segment
        ) s
        WHERE prog IS NOT NULL;
      $$;
    SQL

    execute <<~SQL
      ALTER TABLE content_blocks
        ADD COLUMN bash_programs text[]
        GENERATED ALWAYS AS (
          CASE WHEN tool_name = 'Bash'
            THEN bash_programs(tool_input->>'command')
          END
        ) STORED;
    SQL

    add_index :content_blocks, :bash_programs, using: :gin
  end
end

class DropNewlineSplitFromBashPrograms < ActiveRecord::Migration[8.1]
  SHELL_KEYWORDS = %w[
    if then else elif fi
    for while until do done
    case esac in end function select
  ].freeze

  def up
    replace_function(separator_regex: '\\\\s*(?:&&|\\\\|\\\\||;|\\\\|)\\\\s*',
                     keywords: SHELL_KEYWORDS)
    rebuild_column
  end

  def down
    replace_function(separator_regex: '\\\\s*(?:&&|\\\\|\\\\||;|\\\\||\\\\n)\\\\s*',
                     keywords: nil)
    rebuild_column
  end

  private

  def replace_function(separator_regex:, keywords:)
    keyword_clause =
      if keywords && !keywords.empty?
        list = keywords.map { |k| "'#{k}'" }.join(",")
        "AND prog NOT IN (#{list})"
      else
        ""
      end

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
          FROM regexp_split_to_table(cmd, '#{separator_regex}') AS segment
        ) s
        WHERE prog ~ '[A-Za-z]'
          #{keyword_clause};
      $$;
    SQL
  end

  def rebuild_column
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
end

# `bash_programs()` has only ever returned the first program of a command.
#
# `DropNewlineSplitFromBashPrograms` built the separator pattern in a Ruby
# variable and escaped it one level too many, so the deployed function split on
# `\\s*(?:&&|\\|\\||;|\\|)\\s*` -- a pattern requiring a literal backslash,
# which a real command never contains. `pwd && rg --files .` therefore yielded
# `{pwd}` rather than `{pwd,rg}`. The match pattern in the same function was
# escaped correctly, which is what hid the mistake.
#
# Existing rows need recomputing too: `bash_programs` is a STORED generated
# column, so Postgres does not revisit it when the function changes. Dropping
# and re-adding the column rebuilds it from the `tool_input` already on disk,
# with no re-ingest.
class FixBashProgramsSeparator < ActiveRecord::Migration[8.1]
  def up
    swap_function(to: 2, from: 1)
  end

  def down
    swap_function(to: 1, from: 2)
  end

  private

  # The generated column depends on the function, so Postgres refuses to
  # replace the function while the column exists. Dropping the column first
  # also gives the rebuild for free.
  def swap_function(to:, from:)
    remove_index :content_blocks, :bash_programs
    remove_column :content_blocks, :bash_programs

    update_function :bash_programs, version: to, revert_to_version: from

    execute <<~SQL
      ALTER TABLE content_blocks
        ADD COLUMN bash_programs text[]
        GENERATED ALWAYS AS (
          CASE WHEN tool_kind = 'shell'
            THEN bash_programs(shell_command(tool_input))
          END
        ) STORED;
    SQL

    add_index :content_blocks, :bash_programs, using: :gin
  end
end

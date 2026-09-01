# Brings the two SQL functions the generated columns depend on under `fx`, so
# `db/schema.rb` carries their definitions.
#
# Without this the schema cannot be loaded into an empty database: Postgres
# rejects `content_blocks.bash_command` and `content_blocks.bash_programs`
# because the functions their expressions call do not exist yet. That broke
# `db:prepare` on a fresh clone and `db:test:prepare` in CI.
#
# The functions themselves are unchanged; earlier migrations created them with
# raw `execute`, and the definitions in `db/functions` are `CREATE OR REPLACE`,
# so adopting them is a no-op on a database that already has them.
class AdoptFxManagedFunctions < ActiveRecord::Migration[8.1]
  def up
    create_function :bash_programs
    create_function :shell_command
  end

  def down
    # Deliberately not dropped: `content_blocks` has stored generated columns
    # that depend on both functions, so removing them would fail anyway.
  end
end

# Sessions were named from `first_prompt`, the literally-first non-meta user
# prompt. That is the wrong prompt often enough to be the main thing wrong with
# the sessions index: a session opened with `/clear`, `/model`, or `/login` was
# named after the slash command, XML wrapper and all, and a mid-word `LEFT(_,
# 80)` left the name ending `</command-`.
#
# `title_prompt` replaces it as the title's source. It holds the highest-ranked
# prompt in the session (see `prompt_title_rank`) already cleaned for display,
# so a `/clear` opener loses to the first real request behind it. `first_prompt`
# keeps its literal meaning for querying.
class ImproveSessionTitles < ActiveRecord::Migration[8.1]
  # Mirrors the `title_prompt` subquery in
  # `Sessions::Ingester::RECOMPUTE_AGGREGATES_SQL`, which keeps it current for
  # every session ingested after this runs.
  BACKFILL_SQL = <<~SQL.freeze
    UPDATE sessions s SET title_prompt = (
      SELECT prompt_title(up.content_text)
        FROM user_prompts up
        JOIN messages m ON m.uuid = up.message_uuid
       WHERE m.session_id = s.session_id
         AND up.is_meta = false
         AND m.is_sidechain = false
         AND prompt_title(up.content_text) IS NOT NULL
       ORDER BY prompt_title_rank(up.content_text), m.timestamp
       LIMIT 1
    );
  SQL

  NEW_TITLE_SQL = <<~SQL.freeze
    ALTER TABLE sessions
      ADD COLUMN title text
      GENERATED ALWAYS AS (
        COALESCE(
          NULLIF(btrim(custom_title), ''),
          title_snippet(title_prompt, 90),
          title_snippet(prompt_title(last_prompt), 90),
          'Session ' || left(session_id, 8)
        )
      ) STORED;
  SQL

  OLD_TITLE_SQL = <<~SQL.freeze
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

  def up
    create_function :prompt_title
    create_function :prompt_title_rank
    create_function :title_snippet

    add_column :sessions, :title_prompt, :text
    execute BACKFILL_SQL

    # `title` is STORED and generated, so its expression can only be changed by
    # dropping the column. Re-adding it recomputes every row from data already
    # on disk -- no re-ingest.
    remove_column :sessions, :title
    execute NEW_TITLE_SQL
  end

  def down
    remove_column :sessions, :title
    execute OLD_TITLE_SQL

    remove_column :sessions, :title_prompt

    drop_function :prompt_title_rank
    drop_function :prompt_title
    drop_function :title_snippet
  end
end

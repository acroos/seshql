class AddUniqueIndexesForUpsert < ActiveRecord::Migration[8.1]
  def up
    dedupe_pr_links
    dedupe_file_history_snapshots
    dedupe_content_blocks

    add_index :content_blocks, [ :assistant_message_uuid, :position ],
              unique: true, name: "uniq_content_blocks_on_assistant_position"
    add_index :pr_links, [ :session_id, :pr_repository, :pr_number ],
              unique: true, name: "uniq_pr_links_on_session_repo_number"
    add_index :file_history_snapshots, [ :session_id, :source_message_id ],
              unique: true, name: "uniq_file_history_on_session_source"
  end

  def down
    remove_index :content_blocks, name: "uniq_content_blocks_on_assistant_position"
    remove_index :pr_links, name: "uniq_pr_links_on_session_repo_number"
    remove_index :file_history_snapshots, name: "uniq_file_history_on_session_source"
  end

  private

  def dedupe_pr_links
    execute <<~SQL
      DELETE FROM pr_links a USING pr_links b
      WHERE a.id > b.id
        AND a.session_id = b.session_id
        AND a.pr_repository IS NOT DISTINCT FROM b.pr_repository
        AND a.pr_number IS NOT DISTINCT FROM b.pr_number
    SQL
  end

  def dedupe_file_history_snapshots
    execute <<~SQL
      DELETE FROM file_history_snapshots a USING file_history_snapshots b
      WHERE a.id > b.id
        AND a.session_id = b.session_id
        AND a.source_message_id = b.source_message_id
    SQL
  end

  def dedupe_content_blocks
    execute <<~SQL
      DELETE FROM content_blocks a USING content_blocks b
      WHERE a.id > b.id
        AND a.assistant_message_uuid = b.assistant_message_uuid
        AND a.position = b.position
    SQL
  end
end

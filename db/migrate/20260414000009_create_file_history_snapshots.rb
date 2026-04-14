class CreateFileHistorySnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :file_history_snapshots do |t|
      t.string :session_id, null: false
      t.string :source_message_id, null: false
      t.boolean :is_snapshot_update, default: false
      t.jsonb :tracked_files, default: {}
      t.datetime :snapshot_timestamp
    end

    add_foreign_key :file_history_snapshots, :sessions, column: :session_id, primary_key: :session_id
    add_index :file_history_snapshots, :session_id
    add_index :file_history_snapshots, :source_message_id
  end
end

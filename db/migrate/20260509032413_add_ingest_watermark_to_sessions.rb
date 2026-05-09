class AddIngestWatermarkToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :file_mtime, :datetime
    add_column :sessions, :file_size, :bigint
    add_column :sessions, :last_byte_offset, :bigint, default: 0, null: false
    add_column :sessions, :last_ingested_at, :datetime
    add_index :sessions, :file_mtime
  end
end

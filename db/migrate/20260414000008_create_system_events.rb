class CreateSystemEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :system_events, id: false do |t|
      t.uuid :message_uuid, null: false, primary_key: true
      t.string :subtype, null: false
      t.integer :duration_ms
      t.integer :message_count
      t.integer :hook_count
      t.jsonb :hook_infos, default: []
      t.jsonb :hook_errors, default: []
      t.boolean :prevented_continuation, default: false
      t.string :stop_reason
      t.boolean :has_output, default: false
      t.string :level
      t.boolean :is_meta, default: false
    end

    add_foreign_key :system_events, :messages, column: :message_uuid, primary_key: :uuid
    add_index :system_events, :subtype
  end
end

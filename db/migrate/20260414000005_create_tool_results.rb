class CreateToolResults < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_results, id: false do |t|
      t.uuid :message_uuid, null: false, primary_key: true
      t.string :tool_use_id
      t.uuid :source_assistant_uuid
      t.string :result_type
      t.jsonb :result_content, default: {}
    end

    add_foreign_key :tool_results, :messages, column: :message_uuid, primary_key: :uuid
    add_index :tool_results, :source_assistant_uuid
    add_index :tool_results, :tool_use_id
  end
end

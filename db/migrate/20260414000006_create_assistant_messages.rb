class CreateAssistantMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_messages, id: false do |t|
      t.uuid :message_uuid, null: false, primary_key: true
      t.string :model
      t.string :api_message_id
      t.string :request_id
      t.string :stop_reason
      t.integer :input_tokens, default: 0
      t.integer :output_tokens, default: 0
      t.integer :cache_creation_input_tokens, default: 0
      t.integer :cache_read_input_tokens, default: 0
      t.jsonb :usage_details, default: {}
    end

    add_foreign_key :assistant_messages, :messages, column: :message_uuid, primary_key: :uuid
    add_index :assistant_messages, :model
    add_index :assistant_messages, :api_message_id
  end
end

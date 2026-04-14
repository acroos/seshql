class CreateContentBlocks < ActiveRecord::Migration[8.1]
  def change
    create_enum :block_type, %w[thinking text tool_use]

    create_table :content_blocks do |t|
      t.uuid :assistant_message_uuid, null: false
      t.integer :position, null: false
      t.enum :block_type, enum_type: :block_type, null: false
      t.text :text_content
      t.string :tool_use_id
      t.string :tool_name
      t.jsonb :tool_input, default: {}
      t.text :thinking_signature
    end

    add_foreign_key :content_blocks, :assistant_messages, column: :assistant_message_uuid, primary_key: :message_uuid
    add_index :content_blocks, :assistant_message_uuid
    add_index :content_blocks, :block_type
    add_index :content_blocks, :tool_name
  end
end

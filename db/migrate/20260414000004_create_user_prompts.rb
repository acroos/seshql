class CreateUserPrompts < ActiveRecord::Migration[8.1]
  def change
    create_table :user_prompts, id: false do |t|
      t.uuid :message_uuid, null: false, primary_key: true
      t.text :content_text
      t.string :prompt_id
      t.string :permission_mode
      t.boolean :is_meta, default: false
    end

    add_foreign_key :user_prompts, :messages, column: :message_uuid, primary_key: :uuid
    add_index :user_prompts, :prompt_id
  end
end

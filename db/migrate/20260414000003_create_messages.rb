class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_enum :message_type, %w[user_prompt tool_result assistant system attachment]

    create_table :messages, id: false do |t|
      t.uuid :uuid, null: false, primary_key: true, default: -> { "gen_random_uuid()" }
      t.string :session_id, null: false
      t.uuid :parent_uuid
      t.enum :message_type, enum_type: :message_type, null: false
      t.boolean :is_sidechain, default: false
      t.datetime :timestamp
      t.string :cwd
      t.string :git_branch
      t.string :version
      t.string :entrypoint
      t.string :slug
      t.string :user_type
    end

    add_foreign_key :messages, :sessions, column: :session_id, primary_key: :session_id
    add_index :messages, :session_id
    add_index :messages, :parent_uuid
    add_index :messages, :message_type
    add_index :messages, :timestamp
  end
end

class CreateAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :attachments, id: false do |t|
      t.uuid :message_uuid, null: false, primary_key: true
      t.string :attachment_type
      t.jsonb :attachment_data, default: {}
    end

    add_foreign_key :attachments, :messages, column: :message_uuid, primary_key: :uuid
    add_index :attachments, :attachment_type
  end
end

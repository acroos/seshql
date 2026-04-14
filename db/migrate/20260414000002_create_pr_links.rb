class CreatePrLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :pr_links do |t|
      t.string :session_id, null: false
      t.integer :pr_number
      t.string :pr_url
      t.string :pr_repository
      t.datetime :linked_at
    end

    add_foreign_key :pr_links, :sessions, column: :session_id, primary_key: :session_id
    add_index :pr_links, :session_id
    add_index :pr_links, :pr_repository
  end
end

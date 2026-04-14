class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions, id: false do |t|
      t.string :session_id, null: false, primary_key: true
      t.string :permission_mode
      t.string :custom_title
      t.string :agent_name
      t.text :last_prompt
      t.jsonb :worktree_config, default: {}
      t.string :project_path
      t.timestamps
    end

    add_index :sessions, :project_path
    add_index :sessions, :created_at
  end
end

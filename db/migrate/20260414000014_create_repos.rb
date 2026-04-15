class CreateRepos < ActiveRecord::Migration[8.1]
  def change
    create_table :repos do |t|
      t.string :name, null: false
      t.string :remote_url
      t.string :filesystem_path

      t.timestamps
    end

    add_index :repos, :name, unique: true

    add_reference :sessions, :repo, foreign_key: true, type: :bigint, null: true
  end
end

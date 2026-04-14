class AddInferredTitleToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :inferred_title, :string
  end
end

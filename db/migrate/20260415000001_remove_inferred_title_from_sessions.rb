class RemoveInferredTitleFromSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :sessions, :inferred_title, :string
  end
end

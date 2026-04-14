class AddPrTitleToPrLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_links, :pr_title, :string
  end
end

class CreateDashboards < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards do |t|
      t.string :name, null: false
      t.text :description
      t.timestamps
    end

    create_table :dashboard_panels do |t|
      t.references :dashboard, null: false, foreign_key: true
      t.string :title, null: false
      t.text :sql_query, null: false
      t.string :chart_type, null: false, default: "bar"
      t.integer :position, null: false, default: 0
      t.string :x_column
      t.string :series_column
      t.string :value_column
      t.jsonb :config, default: {}
      t.timestamps
    end
  end
end

class CreateIngestionRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :ingestion_runs do |t|
      t.string :file_path, null: false
      t.string :status, null: false
      t.string :error_class
      t.text :error_message
      t.integer :lines_processed
      t.integer :duration_ms
      t.datetime :run_at, null: false
      t.timestamps
    end
    add_index :ingestion_runs, :run_at
    add_index :ingestion_runs, [ :file_path, :run_at ]
    add_index :ingestion_runs, :status
  end
end

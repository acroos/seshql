class AddCostAndActivityColumns < ActiveRecord::Migration[8.1]
  def change
    # Per-turn cost, computed at ingest from the turn's usage + model rates.
    add_column :assistant_messages, :cost_usd, :decimal, precision: 12, scale: 6

    # Cached-at-ingest session aggregates (populated by Sessions::Ingester).
    add_column :sessions, :user_message_count, :integer, default: 0, null: false
    add_column :sessions, :assistant_message_count, :integer, default: 0, null: false
    add_column :sessions, :active_duration_ms, :bigint, default: 0, null: false
    add_column :sessions, :total_cache_creation_tokens, :bigint, default: 0, null: false
    add_column :sessions, :total_cache_read_tokens, :bigint, default: 0, null: false
    add_column :sessions, :total_cost_usd, :decimal, precision: 12, scale: 6
    add_column :sessions, :pr_link_count, :integer, default: 0, null: false
    add_column :sessions, :files_edited_count, :integer, default: 0, null: false
    add_column :sessions, :git_commit_count, :integer, default: 0, null: false

    add_index :sessions, :total_cost_usd
    add_index :sessions, :active_duration_ms
  end
end

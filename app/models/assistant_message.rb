class AssistantMessage < ApplicationRecord
  self.primary_key = :message_uuid

  belongs_to :message, foreign_key: :message_uuid
  has_one :session, through: :message
  has_many :content_blocks, foreign_key: :assistant_message_uuid

  def total_tokens
    input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens
  end

  # Reconstructs the API `usage` hash from the split-out columns so cost can be
  # recomputed from stored rows (backfills, rate changes) without re-reading
  # the transcript.
  def usage_hash
    {
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "cache_creation_input_tokens" => cache_creation_input_tokens,
      "cache_read_input_tokens" => cache_read_input_tokens
    }.merge(usage_details || {})
  end

  def computed_cost_usd
    Pricing.cost_for_usage(model, usage_hash)
  end
end

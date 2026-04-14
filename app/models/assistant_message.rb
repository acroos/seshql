class AssistantMessage < ApplicationRecord
  self.primary_key = :message_uuid

  belongs_to :message, foreign_key: :message_uuid
  has_one :session, through: :message
  has_many :content_blocks, foreign_key: :assistant_message_uuid

  def total_tokens
    input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens
  end
end

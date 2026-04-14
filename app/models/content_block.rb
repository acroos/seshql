class ContentBlock < ApplicationRecord
  belongs_to :assistant_message, foreign_key: :assistant_message_uuid

  enum :block_type, {
    thinking: "thinking",
    text: "text",
    tool_use: "tool_use"
  }
end

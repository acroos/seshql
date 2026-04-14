class Message < ApplicationRecord
  self.primary_key = :uuid

  belongs_to :session, foreign_key: :session_id
  belongs_to :parent, class_name: "Message", foreign_key: :parent_uuid, optional: true
  has_many :children, class_name: "Message", foreign_key: :parent_uuid

  has_one :user_prompt, foreign_key: :message_uuid
  has_one :tool_result, foreign_key: :message_uuid
  has_one :assistant_message, foreign_key: :message_uuid
  has_one :system_event, foreign_key: :message_uuid
  has_one :attachment, foreign_key: :message_uuid

  enum :message_type, {
    user_prompt: "user_prompt",
    tool_result: "tool_result",
    assistant: "assistant",
    system: "system",
    attachment: "attachment"
  }

  scope :chronological, -> { order(timestamp: :asc) }
  scope :main_chain, -> { where(is_sidechain: false) }
end

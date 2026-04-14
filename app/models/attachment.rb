class Attachment < ApplicationRecord
  self.primary_key = :message_uuid

  belongs_to :message, foreign_key: :message_uuid
  has_one :session, through: :message
end

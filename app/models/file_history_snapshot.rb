class FileHistorySnapshot < ApplicationRecord
  belongs_to :session, foreign_key: :session_id
end

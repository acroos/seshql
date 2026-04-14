class PrLink < ApplicationRecord
  belongs_to :session, foreign_key: :session_id

  def display_name
    pr_title.presence || "#{pr_repository}##{pr_number}"
  end
end

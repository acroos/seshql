class Dashboard < ApplicationRecord
  has_many :panels, class_name: "DashboardPanel", dependent: :destroy

  validates :name, presence: true
end

class Repo < ApplicationRecord
  has_many :sessions, dependent: :nullify

  validates :name, presence: true, uniqueness: true

  def owner
    name.split("/").first
  end

  def repo_name
    name.split("/").last
  end
end

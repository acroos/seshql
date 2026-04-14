module Paginatable
  extend ActiveSupport::Concern

  included do
    scope :page, ->(page, per: 25) {
      page = [page.to_i, 1].max
      offset((page - 1) * per).limit(per)
    }
  end
end

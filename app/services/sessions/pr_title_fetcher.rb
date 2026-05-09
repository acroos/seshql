require "open3"

module Sessions
  class PrTitleFetcher
    def self.call(repository, pr_number)
      new(repository, pr_number).call
    end

    def initialize(repository, pr_number)
      @repository = repository
      @pr_number = pr_number
    end

    def call
      return nil unless @repository.present? && @pr_number.present?

      output, status = Open3.capture2(
        "gh", "pr", "view", @pr_number.to_s,
        "--repo", @repository.to_s,
        "--json", "title", "-q", ".title"
      )
      return output.strip.presence if status.success?
      nil
    rescue => e
      Rails.logger.warn("Could not fetch PR title for #{@repository}##{@pr_number}: #{e.message}")
      nil
    end
  end
end

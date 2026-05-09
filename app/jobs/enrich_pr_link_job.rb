class EnrichPrLinkJob < ApplicationJob
  queue_as :enrich
  discard_on ActiveRecord::RecordNotFound

  def perform(pr_link_id)
    pr = PrLink.find(pr_link_id)
    return if pr.pr_title.present?

    title = Sessions::PrTitleFetcher.call(pr.pr_repository, pr.pr_number)
    pr.update!(pr_title: title) if title
  end
end

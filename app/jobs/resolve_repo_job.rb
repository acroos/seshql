class ResolveRepoJob < ApplicationJob
  queue_as :enrich
  discard_on ActiveRecord::RecordNotFound

  def perform(session_id)
    session = Session.find(session_id)
    return if session.repo_id.present?

    repo = Sessions::RepoResolver.call(session.directory)
    session.update!(repo_id: repo.id) if repo
  end
end

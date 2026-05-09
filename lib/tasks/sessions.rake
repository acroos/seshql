namespace :sessions do
  desc "Ingest all Claude Code session JSONL files from ~/.claude/projects"
  task ingest: :environment do
    SessionsSweepJob.perform_now
  end

  desc "Re-ingest all sessions (drops existing data first)"
  task reingest: :environment do
    puts "Clearing all session data..."
    ContentBlock.delete_all
    AssistantMessage.delete_all
    UserPrompt.delete_all
    ToolResult.delete_all
    SystemEvent.delete_all
    Attachment.delete_all
    Message.delete_all
    PrLink.delete_all
    FileHistorySnapshot.delete_all
    Session.delete_all
    Repo.delete_all
    puts "Done. Re-ingesting..."
    SessionsSweepJob.perform_now
  end

  desc "Backfill PR titles from GitHub for PR links missing a title"
  task backfill_pr_titles: :environment do
    links = PrLink.where(pr_title: nil).where.not(pr_repository: nil, pr_number: nil)
    puts "Found #{links.count} PR links without titles"
    links.find_each { |pr| EnrichPrLinkJob.perform_later(pr.id) }
    puts "Enqueued enrichment jobs."
  end

  desc "Backfill repo associations for sessions missing one"
  task backfill_repos: :environment do
    sessions = Session.where(repo_id: nil).where.not(project_path: nil)
    puts "Found #{sessions.count} sessions without repo associations"
    sessions.find_each { |s| ResolveRepoJob.perform_later(s.session_id) }
    puts "Enqueued resolution jobs."
  end
end

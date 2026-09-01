namespace :sessions do
  desc "Ingest every agent session transcript found on this machine"
  task ingest: :environment do
    SessionsSweepJob.perform_now
  end

  desc "Re-ingest all sessions (drops existing data first)"
  task reingest: :environment do
    puts "Clearing all session data..."
    SessionFile.delete_all
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

  desc "Recompute per-turn costs and session aggregates from already-ingested data"
  task backfill_aggregates: :environment do
    total = AssistantMessage.count
    puts "Recomputing cost for #{total} assistant messages..."
    done = 0
    unpriced = 0
    AssistantMessage.find_in_batches(batch_size: 1_000) do |batch|
      updates = batch.map do |am|
        cost = am.computed_cost_usd
        unpriced += 1 if cost.nil?
        { message_uuid: am.message_uuid, cost_usd: cost }
      end
      AssistantMessage.upsert_all(updates, unique_by: :message_uuid, update_only: [ :cost_usd ])
      done += batch.size
      puts "  #{done}/#{total}"
    end
    puts "  #{unpriced} message(s) had no known model rate" if unpriced.positive?

    puts "Recomputing aggregates for #{Session.count} sessions..."
    Session.find_each { |s| Sessions::Ingester.recompute_aggregates(s.session_id) }
    puts "Done."
  end

  desc "Re-apply each adapter's tool-name to tool-kind mapping to stored blocks"
  task backfill_tool_kinds: :environment do
    # `tool_kind` is written at ingest, so extending an adapter's mapping only
    # affects new rows until this runs.
    Sessions::Adapters.all.each do |adapter|
      names = ContentBlock.joins(assistant_message: { message: :session })
                          .where(sessions: { source: adapter.source })
                          .distinct.pluck(:tool_name).compact

      names.each do |name|
        kind = adapter.tool_kind(name)
        updated = ContentBlock.joins(assistant_message: { message: :session })
                              .where(sessions: { source: adapter.source }, tool_name: name)
                              # IS DISTINCT FROM, so rows whose kind is still
                              # NULL are picked up like any other mismatch.
                              .where("content_blocks.tool_kind IS DISTINCT FROM ?", kind)
                              .update_all(tool_kind: kind)
        puts "  #{adapter.label}: #{name} -> #{kind.inspect} (#{updated} rows)" if updated.positive?
      end
    end
    puts "Done."
  end

  desc "Backfill repo associations for sessions missing one"
  task backfill_repos: :environment do
    sessions = Session.where(repo_id: nil).where.not(directory: nil)
    puts "Found #{sessions.count} sessions without repo associations"
    sessions.find_each { |s| ResolveRepoJob.perform_later(s.session_id) }
    puts "Enqueued resolution jobs."
  end
end

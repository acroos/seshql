namespace :sessions do
  desc "Ingest all Claude Code session JSONL files from ~/.claude/projects"
  task ingest: :environment do
    require "json"

    projects_dir = File.expand_path("~/.claude/projects")
    unless Dir.exist?(projects_dir)
      puts "No projects directory found at #{projects_dir}"
      exit 1
    end

    jsonl_files = Dir.glob(File.join(projects_dir, "**", "*.jsonl"))
    puts "Found #{jsonl_files.size} JSONL files"

    path_lookup = build_project_path_lookup
    ingested = 0
    skipped = 0
    errored = 0

    jsonl_files.each_with_index do |file_path, idx|
      session_id = File.basename(file_path, ".jsonl")
      project_path = derive_project_path(file_path, projects_dir)

      if Session.exists?(session_id: session_id)
        skipped += 1
        next
      end

      begin
        ingest_session(file_path, session_id, project_path, path_lookup)
        ingested += 1
        print "\r[#{idx + 1}/#{jsonl_files.size}] Ingested: #{ingested} | Skipped: #{skipped} | Errors: #{errored}"
      rescue => e
        errored += 1
        $stderr.puts "\nError ingesting #{file_path}: #{e.message}"
        $stderr.puts e.backtrace.first(3).join("\n")
      end
    end

    puts "\nDone! Ingested: #{ingested} | Skipped: #{skipped} | Errors: #{errored}"
  end

  desc "Re-ingest all sessions (drops existing data first)"
  task reingest: :environment do
    puts "Clearing all session data..."
    # Delete in dependency order
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
    Rake::Task["sessions:ingest"].invoke
  end

  desc "Backfill PR titles from GitHub for PR links missing a title"
  task backfill_pr_titles: :environment do
    links = PrLink.where(pr_title: nil).where.not(pr_repository: nil, pr_number: nil)
    puts "Found #{links.count} PR links without titles"

    links.find_each do |pr|
      title = fetch_pr_title(pr.pr_repository, pr.pr_number)
      if title
        pr.update!(pr_title: title)
        puts "  #{pr.pr_repository}##{pr.pr_number} → #{title}"
      else
        puts "  #{pr.pr_repository}##{pr.pr_number} → (failed)"
      end
    end
  end

  desc "Backfill repo associations for sessions missing one"
  task backfill_repos: :environment do
    sessions = Session.where(repo_id: nil).where.not(project_path: nil).to_a
    puts "Found #{sessions.size} sessions without repo associations"

    path_lookup = build_project_path_lookup
    resolved = 0
    failed = 0

    sessions.group_by { |s| s.base_project_path }.each do |base_path, group|
      repo = resolve_repo_from_project_path(base_path, path_lookup)
      if repo
        Session.where(session_id: group.map(&:session_id)).update_all(repo_id: repo.id)
        resolved += group.size
        puts "  #{base_path} → #{repo.name} (#{group.size} sessions)"
      else
        failed += group.size
        puts "  #{base_path} → (could not resolve, #{group.size} sessions)"
      end
    end

    puts "Done! Resolved: #{resolved} | Failed: #{failed}"
  end

end

def ingest_session(file_path, session_id, project_path, path_lookup = nil)
  lines = File.readlines(file_path).map { |l| JSON.parse(l) }
  return if lines.empty?

  ActiveRecord::Base.transaction do
    repo = resolve_repo_from_project_path(project_path, path_lookup)

    session = Session.create!(
      session_id: session_id,
      project_path: project_path,
      repo: repo
    )

    lines.each do |record|
      case record["type"]
      when "permission-mode"
        session.update!(permission_mode: record["permissionMode"])

      when "custom-title"
        session.update!(custom_title: record["customTitle"])

      when "agent-name"
        session.update!(agent_name: record["agentName"])

      when "last-prompt"
        session.update!(last_prompt: record["lastPrompt"])

      when "worktree-state"
        session.update!(worktree_config: record["worktreeSession"] || {})

      when "pr-link"
        pr_title = fetch_pr_title(record["prRepository"], record["prNumber"])
        PrLink.create!(
          session_id: session_id,
          pr_number: record["prNumber"],
          pr_url: record["prUrl"],
          pr_repository: record["prRepository"],
          pr_title: pr_title,
          linked_at: record["timestamp"]
        )

      when "file-history-snapshot"
        snapshot = record["snapshot"] || {}
        FileHistorySnapshot.create!(
          session_id: session_id,
          source_message_id: record["messageId"],
          is_snapshot_update: record["isSnapshotUpdate"] || false,
          tracked_files: snapshot["trackedFileBackups"] || {},
          snapshot_timestamp: snapshot["timestamp"]
        )

      when "user"
        ingest_user_message(record, session)

      when "assistant"
        ingest_assistant_message(record, session)

      when "system"
        ingest_system_message(record, session)

      when "attachment"
        ingest_attachment_message(record, session)
      end
    end

    # Set session created_at from earliest message timestamp
    earliest = session.messages.minimum(:timestamp)
    session.update!(created_at: earliest) if earliest
  end
end

def ingest_user_message(record, session)
  msg_content = record.dig("message", "content")
  uuid = record["uuid"]
  return unless uuid

  if msg_content.is_a?(String)
    # Actual human prompt
    message = create_message(record, session, :user_prompt)
    UserPrompt.find_or_create_by!(message_uuid: message.uuid) do |up|
      up.content_text = msg_content
      up.prompt_id = record["promptId"]
      up.permission_mode = record["permissionMode"]
      up.is_meta = record.dig("isMeta") || false
    end
  elsif msg_content.is_a?(Array)
    # Tool result
    message = create_message(record, session, :tool_result)
    first_result = msg_content.first || {}
    ToolResult.find_or_create_by!(message_uuid: message.uuid) do |tr|
      tr.tool_use_id = first_result["tool_use_id"]
      tr.source_assistant_uuid = record["sourceToolAssistantUUID"]
      tr.result_type = first_result["type"]
      tr.result_content = first_result["content"].is_a?(String) ? { text: first_result["content"] } : (first_result["content"] || {})
    end
  end
end

def ingest_assistant_message(record, session)
  uuid = record["uuid"]
  return unless uuid

  msg = record["message"] || {}
  usage = msg["usage"] || {}

  message = create_message(record, session, :assistant)
  assistant = AssistantMessage.find_or_create_by!(message_uuid: message.uuid) do |am|
    am.model = msg["model"]
    am.api_message_id = msg["id"]
    am.request_id = record["requestId"]
    am.stop_reason = msg["stop_reason"]
    am.input_tokens = usage["input_tokens"] || 0
    am.output_tokens = usage["output_tokens"] || 0
    am.cache_creation_input_tokens = usage["cache_creation_input_tokens"] || 0
    am.cache_read_input_tokens = usage["cache_read_input_tokens"] || 0
    am.usage_details = usage.except("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
  end

  # Content blocks (only if we just created the assistant message)
  return if assistant.content_blocks.any?

  (msg["content"] || []).each_with_index do |block, position|
    next unless %w[thinking text tool_use].include?(block["type"])

    ContentBlock.create!(
      assistant_message_uuid: assistant.message_uuid,
      position: position,
      block_type: block["type"],
      text_content: block["text"] || block["thinking"],
      tool_use_id: block["id"],
      tool_name: block["name"],
      tool_input: block["input"] || {},
      thinking_signature: block["signature"]
    )
  end
end

def ingest_system_message(record, session)
  uuid = record["uuid"]
  return unless uuid

  message = create_message(record, session, :system)
  SystemEvent.find_or_create_by!(message_uuid: message.uuid) do |se|
    se.subtype = record["subtype"] || "unknown"
    se.duration_ms = record["durationMs"]
    se.message_count = record["messageCount"]
    se.hook_count = record["hookCount"]
    se.hook_infos = record["hookInfos"] || []
    se.hook_errors = record["hookErrors"] || []
    se.prevented_continuation = record["preventedContinuation"] || false
    se.stop_reason = record["stopReason"]
    se.has_output = record["hasOutput"] || false
    se.level = record["level"]
    se.is_meta = record["isMeta"] || false
  end
end

def ingest_attachment_message(record, session)
  uuid = record["uuid"]
  return unless uuid

  message = create_message(record, session, :attachment)
  Attachment.find_or_create_by!(message_uuid: message.uuid) do |att|
    att.attachment_type = record.dig("attachment", "type")
    att.attachment_data = record["attachment"] || {}
  end
end

def create_message(record, session, type)
  existing = Message.find_by(uuid: record["uuid"])
  return existing if existing

  Message.create!(
    uuid: record["uuid"],
    session_id: session.session_id,
    parent_uuid: record["parentUuid"],
    message_type: type,
    is_sidechain: record["isSidechain"] || false,
    timestamp: record["timestamp"],
    cwd: record["cwd"],
    git_branch: record["gitBranch"],
    version: record["version"],
    entrypoint: record["entrypoint"],
    slug: record["slug"],
    user_type: record["userType"]
  )
end

# Derive the project path from the file path.
# Regular: projects/<project>/<session>.jsonl -> <project>
# Subagent: projects/<project>/<session>/subagents/<agent>.jsonl -> <project>
def derive_project_path(file_path, projects_dir)
  relative = file_path.sub("#{projects_dir}/", "")
  parts = relative.split("/")
  parts.first
end

# Fetch PR title from GitHub using gh CLI
def fetch_pr_title(repository, pr_number)
  return nil unless repository.present? && pr_number.present?

  require "open3"
  output, status = Open3.capture2("gh", "pr", "view", pr_number.to_s, "--repo", repository.to_s, "--json", "title", "-q", ".title")
  return output.strip.presence if status.success?
  nil
rescue => e
  $stderr.puts "Warning: Could not fetch PR title for #{repository}##{pr_number}: #{e.message}"
  nil
end

# Build a lookup from encoded project directory name → real filesystem path
# using ~/.claude/history.jsonl, which stores the actual paths.
def build_project_path_lookup
  history_file = File.expand_path("~/.claude/history.jsonl")
  return {} unless File.exist?(history_file)

  lookup = {}
  File.foreach(history_file) do |line|
    entry = JSON.parse(line)
    real_path = entry["project"]
    next unless real_path

    # Claude Code encodes paths: / → - and . → -
    encoded = real_path.gsub("/", "-").gsub(".", "-")
    lookup[encoded] = real_path
  end
  lookup
rescue => e
  $stderr.puts "Warning: Could not read history.jsonl: #{e.message}"
  {}
end

# Resolve a repo from a Claude Code project path using history.jsonl lookup.
# Tries: remote URL → owner/repo, then falls back to local/<dirname> for
# local-only git repos.
def resolve_repo_from_project_path(project_path, path_lookup = nil)
  return nil unless project_path.present?

  path_lookup ||= build_project_path_lookup

  # Strip worktree suffix to get the base project directory name
  base_path = project_path.sub(/--claude-worktrees-.*$/, "")
  fs_path = path_lookup[base_path]

  # For worktree paths, resolve to the repo root
  if fs_path && fs_path.include?("/.claude/worktrees/")
    fs_path = fs_path.sub(%r{/\.claude/worktrees/.*$}, "")
  end

  return nil unless fs_path && Dir.exist?(fs_path)
  return nil unless git_repo?(fs_path)

  remote_url = git_remote_url(fs_path)

  if remote_url
    owner_repo = parse_owner_repo(remote_url)
    return nil unless owner_repo

    Repo.find_or_create_by!(name: owner_repo) do |r|
      r.remote_url = remote_url
      r.filesystem_path = fs_path
    end
  else
    # Local-only git repo — use local/<dirname>
    dir_name = File.basename(fs_path)
    local_name = "local/#{dir_name}"

    Repo.find_or_create_by!(name: local_name) do |r|
      r.filesystem_path = fs_path
    end
  end
rescue => e
  $stderr.puts "Warning: Could not resolve repo for #{project_path}: #{e.message}"
  nil
end

def git_repo?(path)
  require "open3"
  _, status = Open3.capture2("git", "-C", path, "rev-parse", "--git-dir")
  status.success?
rescue => e
  false
end

def git_remote_url(path)
  require "open3"
  # Try origin first, then fall back to the first available remote
  output, status = Open3.capture2("git", "-C", path, "remote", "get-url", "origin")
  return output.strip.presence if status.success?

  remotes, status = Open3.capture2("git", "-C", path, "remote")
  return nil unless status.success?

  first_remote = remotes.strip.lines.first&.strip
  return nil unless first_remote

  output, status = Open3.capture2("git", "-C", path, "remote", "get-url", first_remote)
  return output.strip.presence if status.success?
  nil
rescue => e
  nil
end

def parse_owner_repo(remote_url)
  # SSH: git@github.com:owner/repo.git or HTTPS: https://github.com/owner/repo.git
  if remote_url =~ %r{[:/]([^/]+)/([^/]+?)(?:\.git)?$}
    "#{$1}/#{$2}"
  else
    nil
  end
end

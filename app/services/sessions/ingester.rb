module Sessions
  class Ingester
    PROJECTS_DIR = File.expand_path("~/.claude/projects").freeze

    Result = Struct.new(:status, :lines_processed, :error, keyword_init: true)

    def self.call(file_path, path_lookup: nil)
      new(file_path, path_lookup: path_lookup).call
    end

    def initialize(file_path, path_lookup: nil)
      @file_path = file_path
      @path_lookup = path_lookup
    end

    def call
      return Result.new(status: :missing, lines_processed: 0) unless File.exist?(@file_path)

      stat = File.stat(@file_path)
      session_id = File.basename(@file_path, ".jsonl")
      project_path = PathLookup.derive_project_path(@file_path, PROJECTS_DIR)

      session = Session.find_or_initialize_by(session_id: session_id)
      session.project_path ||= project_path

      if up_to_date?(session, stat)
        return Result.new(status: :skipped, lines_processed: 0)
      end

      offset = session.persisted? ? session.last_byte_offset.to_i : 0
      offset = 0 if offset > stat.size

      lines_processed = parse_and_persist(session, offset, stat)

      Result.new(status: :succeeded, lines_processed: lines_processed)
    end

    private

    def up_to_date?(session, stat)
      session.persisted? &&
        session.file_mtime.present? &&
        session.file_size == stat.size &&
        session.file_mtime.to_i == stat.mtime.to_i
    end

    def parse_and_persist(session, offset, stat)
      records = read_records(offset)
      return 0 if records.empty? && session.persisted?

      newly_created = session.new_record?
      new_pr_link_keys = []

      ActiveRecord::Base.transaction do
        session.save! if newly_created

        apply_session_records(session, records)
        new_pr_link_keys = bulk_insert_messages(session, records)

        session.update!(
          file_mtime: stat.mtime,
          file_size: stat.size,
          last_byte_offset: stat.size,
          last_ingested_at: Time.current,
          created_at: earliest_message_timestamp(session) || session.created_at || Time.current
        )
      end

      enqueue_enrichment(session, newly_created, new_pr_link_keys)

      records.size
    end

    def enqueue_enrichment(session, newly_created, new_pr_link_keys)
      ResolveRepoJob.perform_later(session.session_id) if newly_created && session.repo_id.nil?

      return if new_pr_link_keys.empty?
      ids = PrLink.where(
        session_id: session.session_id,
        pr_repository: new_pr_link_keys.map { |k| k[:pr_repository] }.uniq,
        pr_number: new_pr_link_keys.map { |k| k[:pr_number] }.uniq
      ).where(pr_title: nil).pluck(:id)
      ids.each { |id| EnrichPrLinkJob.perform_later(id) }
    end

    def read_records(offset)
      records = []
      File.open(@file_path, "rb") do |f|
        f.seek(offset)
        f.each_line do |line|
          line.chomp!
          next if line.empty?
          begin
            records << JSON.parse(line)
          rescue JSON::ParserError => e
            Rails.logger.warn("Skipping malformed line in #{@file_path}: #{e.message}")
          end
        end
      end
      records
    end

    def apply_session_records(session, records)
      changes = {}
      records.each do |r|
        case r["type"]
        when "permission-mode" then changes[:permission_mode] = r["permissionMode"]
        when "custom-title"    then changes[:custom_title]    = r["customTitle"]
        when "agent-name"      then changes[:agent_name]      = r["agentName"]
        when "last-prompt"     then changes[:last_prompt]     = r["lastPrompt"]
        when "worktree-state"  then changes[:worktree_config] = r["worktreeSession"] || {}
        end
      end
      session.assign_attributes(changes) if changes.any?
      session.save! if session.changed?
    end

    def bulk_insert_messages(session, records)
      messages = []
      user_prompts = []
      tool_results = []
      assistant_msgs = []
      content_blocks = []
      system_events = []
      attachments = []
      pr_links = []
      file_history = []

      records.each do |r|
        case r["type"]
        when "user"       then build_user_record(r, session, messages, user_prompts, tool_results)
        when "assistant"  then build_assistant_record(r, session, messages, assistant_msgs, content_blocks)
        when "system"     then build_system_record(r, session, messages, system_events)
        when "attachment" then build_attachment_record(r, session, messages, attachments)
        when "pr-link"    then pr_links << build_pr_link(r, session)
        when "file-history-snapshot" then file_history << build_file_history(r, session)
        end
      end

      Message.upsert_all(messages, unique_by: :uuid) if messages.any?
      UserPrompt.upsert_all(user_prompts, unique_by: :message_uuid) if user_prompts.any?
      ToolResult.upsert_all(tool_results, unique_by: :message_uuid) if tool_results.any?
      AssistantMessage.upsert_all(assistant_msgs, unique_by: :message_uuid) if assistant_msgs.any?
      ContentBlock.upsert_all(content_blocks, unique_by: "uniq_content_blocks_on_assistant_position") if content_blocks.any?
      SystemEvent.upsert_all(system_events, unique_by: :message_uuid) if system_events.any?
      Attachment.upsert_all(attachments, unique_by: :message_uuid) if attachments.any?
      PrLink.upsert_all(pr_links, unique_by: "uniq_pr_links_on_session_repo_number") if pr_links.any?
      FileHistorySnapshot.upsert_all(file_history, unique_by: "uniq_file_history_on_session_source") if file_history.any?

      pr_links.map { |pl| { pr_repository: pl[:pr_repository], pr_number: pl[:pr_number] } }
    end

    def build_user_record(r, session, messages, user_prompts, tool_results)
      uuid = r["uuid"]
      return unless uuid

      content = r.dig("message", "content")
      if content.is_a?(String)
        messages << message_attrs(r, session, "user_prompt")
        user_prompts << {
          message_uuid: uuid,
          content_text: content,
          prompt_id: r["promptId"],
          permission_mode: r["permissionMode"],
          is_meta: r["isMeta"] || false
        }
      elsif content.is_a?(Array)
        messages << message_attrs(r, session, "tool_result")
        first = content.first || {}
        result_content = if first["content"].is_a?(String)
          { text: first["content"] }
        else
          first["content"] || {}
        end
        tool_results << {
          message_uuid: uuid,
          tool_use_id: first["tool_use_id"],
          source_assistant_uuid: r["sourceToolAssistantUUID"],
          result_type: first["type"],
          result_content: result_content
        }
      end
    end

    def build_assistant_record(r, session, messages, assistant_msgs, content_blocks)
      uuid = r["uuid"]
      return unless uuid

      msg = r["message"] || {}
      usage = msg["usage"] || {}
      messages << message_attrs(r, session, "assistant")
      assistant_msgs << {
        message_uuid: uuid,
        model: msg["model"],
        api_message_id: msg["id"],
        request_id: r["requestId"],
        stop_reason: msg["stop_reason"],
        input_tokens: usage["input_tokens"] || 0,
        output_tokens: usage["output_tokens"] || 0,
        cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
        cache_read_input_tokens: usage["cache_read_input_tokens"] || 0,
        usage_details: usage.except("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
      }

      (msg["content"] || []).each_with_index do |block, position|
        next unless %w[thinking text tool_use].include?(block["type"])
        content_blocks << {
          assistant_message_uuid: uuid,
          position: position,
          block_type: block["type"],
          text_content: block["text"] || block["thinking"],
          tool_use_id: block["id"],
          tool_name: block["name"],
          tool_input: block["input"] || {},
          thinking_signature: block["signature"]
        }
      end
    end

    def build_system_record(r, session, messages, system_events)
      uuid = r["uuid"]
      return unless uuid

      messages << message_attrs(r, session, "system")
      system_events << {
        message_uuid: uuid,
        subtype: r["subtype"] || "unknown",
        duration_ms: r["durationMs"],
        message_count: r["messageCount"],
        hook_count: r["hookCount"],
        hook_infos: r["hookInfos"] || [],
        hook_errors: r["hookErrors"] || [],
        prevented_continuation: r["preventedContinuation"] || false,
        stop_reason: r["stopReason"],
        has_output: r["hasOutput"] || false,
        level: r["level"],
        is_meta: r["isMeta"] || false
      }
    end

    def build_attachment_record(r, session, messages, attachments)
      uuid = r["uuid"]
      return unless uuid

      messages << message_attrs(r, session, "attachment")
      attachments << {
        message_uuid: uuid,
        attachment_type: r.dig("attachment", "type"),
        attachment_data: r["attachment"] || {}
      }
    end

    def build_pr_link(r, session)
      {
        session_id: session.session_id,
        pr_number: r["prNumber"],
        pr_url: r["prUrl"],
        pr_repository: r["prRepository"],
        linked_at: r["timestamp"]
      }
    end

    def build_file_history(r, session)
      snapshot = r["snapshot"] || {}
      {
        session_id: session.session_id,
        source_message_id: r["messageId"],
        is_snapshot_update: r["isSnapshotUpdate"] || false,
        tracked_files: snapshot["trackedFileBackups"] || {},
        snapshot_timestamp: snapshot["timestamp"]
      }
    end

    def message_attrs(r, session, type)
      {
        uuid: r["uuid"],
        session_id: session.session_id,
        parent_uuid: r["parentUuid"],
        message_type: type,
        is_sidechain: r["isSidechain"] || false,
        timestamp: r["timestamp"],
        cwd: r["cwd"],
        git_branch: r["gitBranch"],
        version: r["version"],
        entrypoint: r["entrypoint"],
        slug: r["slug"],
        user_type: r["userType"]
      }
    end

    def earliest_message_timestamp(session)
      Message.where(session_id: session.session_id).minimum(:timestamp)
    end
  end
end

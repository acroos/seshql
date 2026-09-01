module Sessions
  module Adapters
    # Claude Code writes one JSONL file per session under
    # `~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl`, where
    # every line is a self-describing event carrying its own `uuid`.
    class ClaudeCode < Base
      WORKTREE_MARKER = "--claude-worktrees-".freeze

      # Claude's tool names mapped onto the cross-agent `tool_kind`. Tools
      # absent from this table (including MCP tools, handled below) keep a nil
      # kind rather than being forced into an approximate bucket.
      TOOL_KINDS = {
        "Bash" => "shell",
        "BashOutput" => "shell",
        "KillShell" => "shell",
        "Edit" => "edit",
        "Write" => "edit",
        "NotebookEdit" => "edit",
        "Read" => "read",
        "Grep" => "search",
        "Glob" => "search",
        "WebSearch" => "web_search",
        "WebFetch" => "web_fetch",
        "Task" => "agent",
        "Agent" => "agent",
        "TaskCreate" => "agent",
        "TaskUpdate" => "agent",
        "TaskStop" => "agent",
        "TaskOutput" => "agent",
        "Skill" => "agent",
        "ToolSearch" => "search",
        "TodoWrite" => "plan",
        "ExitPlanMode" => "plan",
        "AskUserQuestion" => "user_input",
        "SendUserFile" => "user_input"
      }.freeze

      class << self
        def source = "claude_code"

        def label = "Claude Code"

        def home = File.expand_path(ENV["CLAUDE_HOME"].presence || "~/.claude")

        def projects_dir = File.join(home, "projects")

        def roots = [ projects_dir ]

        def session_id_for(path) = File.basename(path, ".jsonl")

        def tool_kind(tool_name)
          return nil if tool_name.blank?
          TOOL_KINDS[tool_name] || ("mcp" if tool_name.start_with?("mcp__"))
        end
      end

      def initialize(session_id:, file_path:, path_lookup: nil)
        super(session_id: session_id, file_path: file_path)
        @path_lookup = path_lookup
      end

      def parse(records)
        parsed.set_session(session_attrs_from_path)

        records.each do |record|
          apply_session_record(record)

          case record["type"]
          when "user"       then build_user(record)
          when "assistant"  then build_assistant(record)
          when "system"     then build_system(record)
          when "attachment" then build_attachment(record)
          when "pr-link"    then build_pr_link(record)
          when "file-history-snapshot" then build_file_history(record)
          end
        end

        parsed
      end

      private

      def project_path
        @project_path ||= begin
          relative = file_path.sub("#{self.class.projects_dir}/", "")
          relative.split("/").first
        end
      end

      # `~/.claude/history.jsonl` records the real filesystem path for each
      # encoded project directory, which is the only reliable way to decode a
      # path whose directory names contain dots or dashes. The naive decode is
      # a fallback for projects that never made it into the history file.
      def session_attrs_from_path
        base = project_path.to_s.sub(/#{Regexp.escape(WORKTREE_MARKER)}.*\z/, "")
        worktree = project_path.to_s.split(WORKTREE_MARKER, 2)[1].presence

        {
          project_path: project_path,
          directory: path_lookup[base].presence || naive_decode(base),
          worktree: worktree
        }
      end

      def naive_decode(encoded)
        return nil if encoded.blank?
        "/#{encoded.sub(/\A-/, '').tr('-', '/')}"
      end

      def path_lookup
        @path_lookup ||= PathLookup.build
      end

      SESSION_RECORD_FIELDS = {
        "permission-mode" => [ :permission_mode, "permissionMode" ],
        "custom-title"    => [ :custom_title,    "customTitle" ],
        "agent-name"      => [ :agent_name,      "agentName" ],
        "last-prompt"     => [ :last_prompt,     "lastPrompt" ]
      }.freeze

      def apply_session_record(record)
        if (field = SESSION_RECORD_FIELDS[record["type"]])
          column, key = field
          parsed.set_session(column => record[key])
        elsif record["type"] == "worktree-state"
          parsed.set_session(worktree_config: record["worktreeSession"] || {})
        end
      end

      def build_user(record)
        uuid = record["uuid"]
        return unless uuid

        content = record.dig("message", "content")

        if content.is_a?(String)
          parsed.messages << message_attrs(record, "user_prompt")
          parsed.user_prompts << {
            message_uuid: uuid,
            content_text: content,
            prompt_id: record["promptId"],
            permission_mode: record["permissionMode"],
            is_meta: record["isMeta"] || false
          }
        elsif content.is_a?(Array)
          parsed.messages << message_attrs(record, "tool_result")
          first = content.first || {}
          result_content = first["content"].is_a?(String) ? { text: first["content"] } : (first["content"] || {})
          parsed.tool_results << {
            message_uuid: uuid,
            tool_use_id: first["tool_use_id"],
            source_assistant_uuid: record["sourceToolAssistantUUID"],
            result_type: first["type"],
            result_content: result_content
          }
        end
      end

      def build_assistant(record)
        uuid = record["uuid"]
        return unless uuid

        message = record["message"] || {}
        usage = message["usage"] || {}

        parsed.messages << message_attrs(record, "assistant")
        parsed.assistant_messages << {
          message_uuid: uuid,
          model: message["model"],
          api_message_id: message["id"],
          request_id: record["requestId"],
          stop_reason: message["stop_reason"],
          input_tokens: usage["input_tokens"] || 0,
          output_tokens: usage["output_tokens"] || 0,
          cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
          cache_read_input_tokens: usage["cache_read_input_tokens"] || 0,
          usage_details: usage.except("input_tokens", "output_tokens",
                                      "cache_creation_input_tokens", "cache_read_input_tokens"),
          cost_usd: Pricing.cost_for_usage(message["model"], usage, source: self.class.source)
        }

        (message["content"] || []).each_with_index do |block, position|
          next unless %w[thinking text tool_use].include?(block["type"])
          parsed.content_blocks << {
            assistant_message_uuid: uuid,
            position: position,
            block_type: block["type"],
            text_content: block["text"] || block["thinking"],
            tool_use_id: block["id"],
            tool_name: block["name"],
            tool_kind: self.class.tool_kind(block["name"]),
            tool_input: block["input"] || {},
            thinking_signature: block["signature"]
          }
        end
      end

      def build_system(record)
        uuid = record["uuid"]
        return unless uuid

        parsed.messages << message_attrs(record, "system")
        parsed.system_events << {
          message_uuid: uuid,
          subtype: record["subtype"] || "unknown",
          duration_ms: record["durationMs"],
          message_count: record["messageCount"],
          hook_count: record["hookCount"],
          hook_infos: record["hookInfos"] || [],
          hook_errors: record["hookErrors"] || [],
          prevented_continuation: record["preventedContinuation"] || false,
          stop_reason: record["stopReason"],
          has_output: record["hasOutput"] || false,
          level: record["level"],
          is_meta: record["isMeta"] || false
        }
      end

      def build_attachment(record)
        uuid = record["uuid"]
        return unless uuid

        parsed.messages << message_attrs(record, "attachment")
        parsed.attachments << {
          message_uuid: uuid,
          attachment_type: record.dig("attachment", "type"),
          attachment_data: record["attachment"] || {}
        }
      end

      def build_pr_link(record)
        parsed.pr_links << {
          session_id: session_id,
          pr_number: record["prNumber"],
          pr_url: record["prUrl"],
          pr_repository: record["prRepository"],
          linked_at: record["timestamp"]
        }
      end

      def build_file_history(record)
        snapshot = record["snapshot"] || {}
        parsed.file_history_snapshots << {
          session_id: session_id,
          source_message_id: record["messageId"],
          is_snapshot_update: record["isSnapshotUpdate"] || false,
          tracked_files: snapshot["trackedFileBackups"] || {},
          snapshot_timestamp: snapshot["timestamp"]
        }
      end

      def message_attrs(record, type)
        {
          uuid: record["uuid"],
          session_id: session_id,
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
        }
      end
    end
  end
end

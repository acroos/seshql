module Sessions
  module Adapters
    # Codex writes date-partitioned "rollout" files under
    # `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread-id>[_<rollout-id>].jsonl`,
    # optionally zstd-compressed after the fact.
    #
    # Every line is `{timestamp, ordinal, type, payload}`. Unlike Claude Code,
    # nothing in the file carries a message identifier, a per-message model, or
    # a per-message cwd, so this adapter reconstructs all three:
    #
    #   * identity - synthesized from the thread id plus the line's ordinal
    #   * model    - carried forward from the most recent `turn_context`
    #   * usage    - matched to an assistant turn via `token_usage_record`
    #
    # Codex persists content twice when a thread is in the (default) Legacy
    # history mode: once as a `response_item` and again as an `event_msg`.
    # Only `response_item` lines are read for content, so nothing is counted
    # twice in either history mode.
    class Codex < Base
      class CompressedTranscriptUnsupported < StandardError; end

      SESSIONS_SUBDIR = "sessions".freeze
      ARCHIVED_SESSIONS_SUBDIR = "archived_sessions".freeze
      ROLLOUT_FILENAME =
        /\Arollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<thread_id>[^_.]+)(?:_[^.]+)?\.jsonl(?:\.zst)?\z/

      # Assistant-authored response items, in the order they can appear within
      # one model response.
      ASSISTANT_ITEMS = %w[
        message agent_message reasoning function_call custom_tool_call
        local_shell_call tool_search_call web_search_call image_generation_call
      ].freeze

      TOOL_OUTPUT_ITEMS = %w[
        function_call_output custom_tool_call_output tool_search_output
      ].freeze

      TOOL_KINDS = {
        "shell" => "shell",
        "local_shell" => "shell",
        "exec_command" => "shell",
        "apply_patch" => "edit",
        "write_file" => "edit",
        "read_file" => "read",
        "view_image" => "read",
        "grep" => "search",
        "file_search" => "search",
        "tool_search" => "search",
        "web_search" => "web_search",
        "update_plan" => "plan"
      }.freeze

      # Codex renamed its turn lifecycle events; 0.151 writes `task_*` while
      # newer builds write `turn_*`. Both mean the same thing.
      TURN_STARTED_EVENTS = %w[turn_started task_started].freeze
      TURN_COMPLETE_EVENTS = %w[turn_complete task_complete].freeze
      TURN_ABORTED_EVENTS = %w[turn_aborted task_aborted].freeze

      # Content whose harness classification starts with this belongs to the
      # operator. `ContentItemKind` is an open string, so everything else --
      # `agents_md.instructions`, `environments.environment_context`,
      # `host_skills.instructions`, and whatever gets added next -- is context
      # the harness injected, even when it is sent with role "user".
      USER_AUTHORED_KIND_PREFIX = "user.".freeze

      # In Code Mode a single `exec` tool takes a JavaScript program that calls
      # the real tools on a `tools` object, so the shell command and the files
      # touched are nested one level down. See `code_mode_block`.
      CODE_MODE_TOOL = "exec".freeze
      CODE_MODE_CALL = /tools\.([A-Za-z0-9_]+)\s*\(/
      CODE_MODE_SHELL_CALL = "tools.exec_command(".freeze
      # `*** Add File: path` and friends, whether the patch arrived with real
      # newlines or as a JavaScript string literal with escaped ones.
      PATCH_FILE = /\*\*\*\s+(?:Add|Update|Delete)\s+File:\s*(.+?)(?:\\n|\n|")/
      PATCH_MOVE = /\*\*\*\s+Move\s+to:\s*(.+?)(?:\\n|\n|")/

      # Session facts worth keeping that have no column of their own.
      SESSION_METADATA_KEYS = %w[
        originator cli_version source model_provider history_mode
        parent_thread_id forked_from_id session_id agent_path
      ].freeze

      class << self
        def source = "codex"

        def label = "Codex"

        def home = File.expand_path(ENV["CODEX_HOME"].presence || "~/.codex")

        def roots
          [ File.join(home, SESSIONS_SUBDIR), File.join(home, ARCHIVED_SESSIONS_SUBDIR) ]
        end

        def file_patterns
          [ File.join("**", "rollout-*.jsonl"), File.join("**", "rollout-*.jsonl.zst") ]
        end

        def transcript?(path) = ROLLOUT_FILENAME.match?(File.basename(path))

        # A reverted thread keeps its thread id and gets a fresh rollout id, so
        # the thread id is what identifies the session across its files.
        def session_id_for(path)
          ROLLOUT_FILENAME.match(File.basename(path))&.[](:thread_id)
        end

        # Usage records can trail the assistant items they belong to, so a
        # partial read would attribute cost to the wrong turn or drop it.
        # Codex files are always re-read in full; the upserts make that safe.
        def resumable?(_path) = false

        def compressed?(path) = path.end_with?(".zst")

        def each_record(path, offset: 0, &block)
          return super unless compressed?(path)

          decompress(path) { |io| stream_records(io, path, &block) }
        end

        def tool_kind(tool_name)
          return nil if tool_name.blank?
          # MCP tools arrive namespaced, e.g. "mcp__linear__create_issue".
          return "mcp" if tool_name.start_with?("mcp__", "mcp.")
          TOOL_KINDS[tool_name]
        end

        private

        # Shelling out to `zstd` keeps SeshQL free of a native decompression
        # dependency for a format most installs will never produce.
        def decompress(path)
          IO.popen([ "zstd", "-dc", path ], "rb") { |io| yield io }
        rescue Errno::ENOENT
          raise CompressedTranscriptUnsupported,
                "#{path} is zstd-compressed but the `zstd` binary is not installed"
        end
      end

      def parse(records)
        records = records.to_a
        index_turn_usage(records)

        records.each_with_index do |record, index|
          @ordinal = record["ordinal"] || index
          @timestamp = record["timestamp"]
          payload = record["payload"] || {}

          case record["type"]
          when "session_meta"  then apply_session_meta(payload)
          when "turn_context"  then apply_turn_context(payload)
          when "event_msg"     then apply_event(payload)
          when "response_item" then apply_response_item(payload, record["metadata"])
          when "compacted"     then record_compaction(payload)
          end
        end

        flush_assistant
        absorb_unassigned_usage
        parsed
      end

      private

      attr_reader :ordinal, :timestamp

      # Groups every turn's usage in file order, so the Nth model response
      # within a turn can be matched to the Nth usage reading.
      #
      # Codex reports usage two different ways depending on version: dedicated
      # `token_usage_record` lines, or `token_count` events carrying
      # `info.last_token_usage`. Only `token_count` events have no turn id of
      # their own, hence the running turn. When a transcript has both, the
      # dedicated records win so nothing is counted twice.
      def index_turn_usage(records)
        @last_assistant_by_turn = {}
        from_records = Hash.new { |hash, key| hash[key] = [] }
        from_events = Hash.new { |hash, key| hash[key] = [] }
        turn = nil

        records.each do |record|
          payload = record["payload"] || {}

          case record["type"]
          when "turn_context"
            turn = payload["turn_id"] || turn
          when "response_item"
            turn = turn_id_of(payload, record["metadata"]) || turn
          when "token_usage_record"
            from_records[payload["turn_id"] || turn] << payload
          when "event_msg"
            turn = payload["turn_id"] || turn if turn_event?(payload["type"])
            if payload["type"] == "token_count"
              usage = payload.dig("info", "last_token_usage")
              from_events[turn] << { "usage" => usage } if usage.present?
            end
          end
        end

        @turn_usage = from_records.any? ? from_records : from_events
        @turn_usage.default_proc = proc { |hash, key| hash[key] = [] }
      end

      def turn_event?(type)
        TURN_STARTED_EVENTS.include?(type) ||
          TURN_COMPLETE_EVENTS.include?(type) ||
          TURN_ABORTED_EVENTS.include?(type)
      end

      # The turn id rides in the response item's passthrough metadata, with
      # the rollout line's own metadata as a fallback.
      def turn_id_of(payload, line_metadata)
        [ payload["internal_chat_message_metadata_passthrough"], line_metadata ]
          .grep(Hash).filter_map { |metadata| metadata["turn_id"].presence }.first
      end

      def apply_session_meta(payload)
        git = payload["git"] || {}
        @cwd = payload["cwd"] || @cwd
        @git_branch = git["branch"] || @git_branch
        @cli_version = payload["cli_version"] || @cli_version

        parsed.set_session(
          directory: @cwd,
          project_path: @cwd,
          agent_name: payload["agent_role"] || payload["agent_nickname"],
          source_metadata: payload.slice(*SESSION_METADATA_KEYS)
                                  .merge("git" => git.presence).compact
        )
      end

      def apply_turn_context(payload)
        # A turn's context is written at turn start, so flushing here keeps an
        # assistant message from spanning a model or turn change.
        flush_assistant
        @turn_id = payload["turn_id"] || @turn_id
        @model = payload["model"] || @model
        @cwd = payload["cwd"] || @cwd
        @effort = payload["effort"]
        parsed.set_session(directory: @cwd)
      end

      # Only events carrying turn metadata are read. The rest are either
      # transient or duplicates of a `response_item`.
      def apply_event(payload)
        type = payload["type"]

        if TURN_STARTED_EVENTS.include?(type)
          @turn_id = payload["turn_id"] || @turn_id
        elsif TURN_COMPLETE_EVENTS.include?(type)
          @turn_id = payload["turn_id"] || @turn_id
          record_turn_duration(payload)
        elsif TURN_ABORTED_EVENTS.include?(type)
          record_system_event("turn_aborted", stop_reason: payload["reason"])
        end
      end

      # Mirrors Claude Code's `turn_duration` system event so session
      # aggregates compute active duration identically for both agents.
      def record_turn_duration(payload)
        duration = payload["duration_ms"]
        return if duration.nil?

        record_system_event("turn_duration",
                            duration_ms: duration,
                            stop_reason: payload["error"].present? ? "error" : nil)
      end

      def record_compaction(payload)
        flush_assistant
        record_system_event("compacted", has_output: payload["message"].present?)
      end

      def record_system_event(subtype, duration_ms: nil, stop_reason: nil, has_output: false)
        uuid = synthetic_uuid("system", ordinal, subtype)
        parsed.messages << message_attrs(uuid, "system")
        parsed.system_events << {
          message_uuid: uuid,
          subtype: subtype,
          duration_ms: duration_ms,
          hook_infos: [],
          hook_errors: [],
          prevented_continuation: false,
          stop_reason: stop_reason,
          has_output: has_output,
          is_meta: false
        }
      end

      def apply_response_item(payload, metadata)
        @turn_id = turn_id_of(payload, metadata) || @turn_id
        type = payload["type"]

        if TOOL_OUTPUT_ITEMS.include?(type)
          flush_assistant
          build_tool_result(payload)
        elsif type == "message" && payload["role"].to_s != "assistant"
          flush_assistant
          build_user_prompt(payload)
        elsif ASSISTANT_ITEMS.include?(type)
          append_assistant_block(payload)
        end
      end

      def build_user_prompt(payload)
        uuid = synthetic_uuid("message", ordinal)
        authored, text = operator_text(payload)

        parsed.messages << message_attrs(uuid, "user_prompt")
        parsed.user_prompts << {
          message_uuid: uuid,
          content_text: text,
          prompt_id: payload["id"],
          permission_mode: nil,
          # `is_meta` marks context the harness injected rather than something
          # the operator typed.
          is_meta: !authored
        }
      end

      # Splits a message into "what the operator actually typed" and the rest.
      #
      # Role alone cannot decide this: Codex sends AGENTS.md and the
      # environment context with role "user", so trusting the role makes a
      # repository's instruction file look like the opening prompt and turns it
      # into the session title. When the harness classifies the content, that
      # classification decides, and only the operator's own entries become the
      # prompt text. Older rollouts carry no classification, so there the role
      # is still the best available signal.
      def operator_text(payload)
        content = Array(payload["content"])
        kinds = content_item_kinds(payload)
        return [ payload["role"].to_s == "user", content_text(content) ] if kinds.empty?

        authored = content.each_with_index.select do |_, index|
          kinds[index].to_s.start_with?(USER_AUTHORED_KIND_PREFIX)
        end.map(&:first)

        return [ false, content_text(content) ] if authored.empty?

        [ true, content_text(authored) ]
      end

      def content_item_kinds(payload)
        Array(payload.dig("internal_chat_message_metadata_passthrough", "content_item_kinds"))
      end

      def build_tool_result(payload)
        uuid = synthetic_uuid("tool_result", ordinal)
        output = payload["output"]

        parsed.messages << message_attrs(uuid, "tool_result")
        parsed.tool_results << {
          message_uuid: uuid,
          tool_use_id: payload["call_id"] || payload["id"],
          source_assistant_uuid: @last_assistant_uuid,
          result_type: payload["type"],
          result_content: output.is_a?(String) ? { text: output } : (output || {})
        }
      end

      # Assistant-authored items are buffered so the reasoning, text, and tool
      # calls of a single model response land on one assistant message, the way
      # Claude Code already records them.
      def append_assistant_block(payload)
        @assistant_blocks ||= []
        @assistant_ordinal ||= ordinal
        @assistant_timestamp ||= timestamp
        @assistant_turn_id ||= @turn_id

        block = assistant_block(payload, @assistant_blocks.size)
        @assistant_blocks << block if block
      end

      def assistant_block(payload, position)
        base = { position: position, tool_input: {} }
        call_id = payload["call_id"] || payload["id"]

        case payload["type"]
        when "message", "agent_message"
          base.merge(block_type: "text", text_content: content_text(payload["content"]))
        when "reasoning"
          base.merge(block_type: "thinking",
                     text_content: reasoning_text(payload),
                     thinking_signature: payload["encrypted_content"])
        when "function_call"
          tool_use(base, call_id, payload["name"], json_arguments(payload["arguments"]))
        when "custom_tool_call"
          if payload["name"] == CODE_MODE_TOOL
            code_mode_block(base, call_id, payload["input"])
          else
            tool_use(base, call_id, payload["name"], json_arguments(payload["input"]))
          end
        when "local_shell_call"
          tool_use(base, call_id, "local_shell", payload["action"] || {})
        when "tool_search_call"
          tool_use(base, call_id, "tool_search",
                   payload.slice("execution", "arguments"))
        when "web_search_call"
          tool_use(base, call_id, "web_search", payload["action"] || {})
        when "image_generation_call"
          tool_use(base, call_id, "image_generation",
                   payload.slice("revised_prompt", "status"))
        end
      end

      def tool_use(base, call_id, tool_name, tool_input, tool_kind: nil)
        base.merge(block_type: "tool_use",
                   tool_use_id: call_id,
                   tool_name: tool_name,
                   tool_kind: tool_kind || self.class.tool_kind(tool_name),
                   tool_input: tool_input)
      end

      # Lifts what a Code Mode program actually did up to where the rest of
      # SeshQL can see it: the shell command into `command` and the patched
      # paths into `file_path`, which is what the `bash_command`,
      # `bash_programs`, and `files_edited_count` columns read. The program
      # itself is kept under `program`, so nothing is lost to the extraction.
      def code_mode_block(base, call_id, program)
        program = program.to_s
        invoked = program.scan(CODE_MODE_CALL).flatten.uniq
        commands = code_mode_commands(program)
        paths = code_mode_paths(program)

        input = { "program" => program, "tools" => invoked }
        # Several commands in one program are joined the way the program runs
        # them, so `bash_programs` sees each one.
        input["command"] = commands.join("; ") if commands.any?
        input["file_path"] = paths.first if paths.any?
        input["file_paths"] = paths if paths.many?

        tool_use(base, call_id, CODE_MODE_TOOL, input, tool_kind: code_mode_kind(invoked))
      end

      # A program that both edits and runs commands gets the edit kind, since
      # that is the harder signal to recover from the raw program text.
      def code_mode_kind(invoked)
        kinds = invoked.filter_map { |name| self.class.tool_kind(name) }.uniq
        return "edit" if kinds.include?("edit")
        return "shell" if kinds.include?("shell")

        kinds.first || "code_mode"
      end

      def code_mode_commands(program)
        scan_calls(program, CODE_MODE_SHELL_CALL).filter_map { |args| args["cmd"].presence }
      end

      def code_mode_paths(program)
        (program.scan(PATCH_FILE) + program.scan(PATCH_MOVE)).flatten.map(&:strip).uniq
      end

      # Pulls the JSON object literal out of each `tools.foo({...})` call.
      # Codex emits plain JSON for these arguments, so a brace scan is enough
      # and no JavaScript has to be interpreted.
      def scan_calls(program, prefix)
        calls = []
        offset = 0

        while (start = program.index(prefix, offset))
          brace = program.index("{", start + prefix.length)
          offset = start + prefix.length
          next if brace.nil?

          body = balanced_braces(program, brace)
          next if body.nil?

          offset = brace + body.length
          parsed_args = JSON.parse(body) rescue nil
          calls << parsed_args if parsed_args.is_a?(Hash)
        end

        calls
      end

      def balanced_braces(text, start)
        depth = 0
        in_string = false
        escaped = false

        text[start..].each_char.with_index do |char, index|
          if in_string
            if escaped then escaped = false
            elsif char == "\\" then escaped = true
            elsif char == '"' then in_string = false
            end
            next
          end

          case char
          when '"' then in_string = true
          when "{" then depth += 1
          when "}"
            depth -= 1
            return text[start, index + 1] if depth.zero?
          end
        end

        nil
      end

      def flush_assistant
        blocks = @assistant_blocks
        return if blocks.blank?

        uuid = synthetic_uuid("assistant", @assistant_ordinal)
        turn_id = @assistant_turn_id
        attrs = assistant_message_attrs(uuid, next_usage_for(turn_id))

        parsed.messages << message_attrs(uuid, "assistant", at: @assistant_timestamp)
        parsed.assistant_messages << attrs
        blocks.each { |block| parsed.content_blocks << block.merge(assistant_message_uuid: uuid) }

        @last_assistant_uuid = uuid
        @last_assistant_by_turn[turn_id] = attrs
        @assistant_blocks = @assistant_ordinal = @assistant_timestamp = @assistant_turn_id = nil
      end

      def assistant_message_attrs(uuid, usage)
        usage ||= {}
        # Codex reports `input_tokens` inclusive of the cached portion, while
        # SeshQL stores the three input buckets side by side.
        cached = usage["cached_input_tokens"].to_i

        attrs = {
          message_uuid: uuid,
          model: @model,
          api_message_id: usage["response_id"],
          request_id: nil,
          stop_reason: nil,
          input_tokens: [ usage["input_tokens"].to_i - cached, 0 ].max,
          output_tokens: usage["output_tokens"].to_i,
          cache_creation_input_tokens: usage["cache_write_input_tokens"].to_i,
          cache_read_input_tokens: cached,
          usage_details: usage.slice("reasoning_output_tokens", "total_tokens")
                              .merge("effort" => @effort, "turn_id" => @assistant_turn_id).compact
        }
        attrs.merge(cost_usd: price(attrs))
      end

      # A turn's usage records are handed out in order: the first assistant
      # message of a turn takes the first record, and so on.
      def next_usage_for(turn_id)
        records = @turn_usage[turn_id]
        return nil if records.blank?

        record = records.shift
        usage = record["usage"] || record["turn_token_usage"] || {}
        usage.merge("response_id" => record["response_id"])
      end

      # A turn with more model responses than assistant messages (a tool call
      # that produced no visible output, say) leaves usage records unclaimed.
      # Folding them into that turn's last assistant message keeps session
      # token and cost totals whole.
      def absorb_unassigned_usage
        @turn_usage.each do |turn_id, records|
          next if records.empty?
          target = @last_assistant_by_turn[turn_id]
          next if target.nil?

          records.each { |record| add_usage(target, record["usage"] || {}) }
          records.clear
          target[:cost_usd] = price(target)
        end
      end

      def add_usage(attrs, usage)
        cached = usage["cached_input_tokens"].to_i
        attrs[:input_tokens] += [ usage["input_tokens"].to_i - cached, 0 ].max
        attrs[:output_tokens] += usage["output_tokens"].to_i
        attrs[:cache_creation_input_tokens] += usage["cache_write_input_tokens"].to_i
        attrs[:cache_read_input_tokens] += cached
      end

      def price(attrs)
        Pricing.cost_for_usage(
          attrs[:model],
          {
            "input_tokens" => attrs[:input_tokens],
            "output_tokens" => attrs[:output_tokens],
            "cache_creation_input_tokens" => attrs[:cache_creation_input_tokens],
            "cache_read_input_tokens" => attrs[:cache_read_input_tokens]
          },
          source: self.class.source
        )
      end

      def message_attrs(uuid, type, at: nil)
        {
          uuid: uuid,
          session_id: session_id,
          parent_uuid: nil,
          message_type: type,
          is_sidechain: false,
          timestamp: at || timestamp,
          cwd: @cwd,
          git_branch: @git_branch,
          version: @cli_version,
          entrypoint: nil,
          slug: nil,
          user_type: nil
        }
      end

      def content_text(content)
        return content if content.is_a?(String)
        return nil unless content.is_a?(Array)

        content.filter_map { |item| item["text"] }.join("\n").presence
      end

      def reasoning_text(payload)
        summary = Array(payload["summary"]).filter_map { |item| item["text"] }
        content = Array(payload["content"]).filter_map { |item| item["text"] }
        (summary + content).join("\n").presence
      end

      def json_arguments(raw)
        return {} if raw.blank?
        return raw if raw.is_a?(Hash)

        arguments = JSON.parse(raw)
        arguments.is_a?(Hash) ? arguments : { "arguments" => arguments }
      rescue JSON::ParserError
        { "raw" => raw }
      end
    end
  end
end

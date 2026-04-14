class SqlConsoleController < ApplicationController
  MAX_ROWS = 500
  STATEMENT_TIMEOUT_MS = 10_000

  FORBIDDEN_PATTERNS = [
    /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|COPY)\b/i,
    /\b(INTO\s+OUTFILE|LOAD\s+DATA|EXEC|EXECUTE)\b/i,
    /;\s*\S/,  # multiple statements
  ].freeze

  SCHEMA_REFERENCE = {
    "sessions" => %w[session_id permission_mode custom_title agent_name last_prompt project_path worktree_config created_at updated_at],
    "messages" => %w[uuid session_id parent_uuid message_type is_sidechain timestamp cwd git_branch version entrypoint slug user_type],
    "user_prompts" => %w[message_uuid content_text prompt_id permission_mode is_meta],
    "assistant_messages" => %w[message_uuid model api_message_id request_id stop_reason input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens usage_details],
    "content_blocks" => %w[id assistant_message_uuid position block_type text_content tool_use_id tool_name tool_input thinking_signature],
    "tool_results" => %w[message_uuid tool_use_id source_assistant_uuid result_type result_content],
    "system_events" => %w[message_uuid subtype duration_ms message_count hook_count prevented_continuation stop_reason has_output level is_meta hook_infos hook_errors],
    "pr_links" => %w[id session_id pr_number pr_url pr_repository linked_at],
    "file_history_snapshots" => %w[id session_id source_message_id is_snapshot_update tracked_files snapshot_timestamp],
    "attachments" => %w[message_uuid attachment_type attachment_data],
  }.freeze

  EXAMPLE_QUERIES = [
    {
      label: "Bash tool calls containing 'git' or 'gh'",
      sql: <<~SQL.strip
        SELECT
          COUNT(*) AS call_count,
          COALESCE(SUM(am.input_tokens + am.output_tokens + am.cache_creation_input_tokens + am.cache_read_input_tokens), 0) AS total_tokens
        FROM content_blocks cb
        JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
        WHERE cb.block_type = 'tool_use'
          AND cb.tool_name = 'Bash'
          AND (cb.tool_input::text ILIKE '%git%' OR cb.tool_input::text ILIKE '%gh %')
      SQL
    },
    {
      label: "Top 10 sessions by token usage",
      sql: <<~SQL.strip
        SELECT
          s.session_id,
          COALESCE(s.custom_title, LEFT(s.last_prompt, 60)) AS title,
          SUM(am.input_tokens + am.output_tokens + am.cache_creation_input_tokens + am.cache_read_input_tokens) AS total_tokens
        FROM sessions s
        JOIN messages m ON m.session_id = s.session_id
        JOIN assistant_messages am ON am.message_uuid = m.uuid
        GROUP BY s.session_id, s.custom_title, s.last_prompt
        ORDER BY total_tokens DESC
        LIMIT 10
      SQL
    },
    {
      label: "Tool usage frequency by tool name",
      sql: <<~SQL.strip
        SELECT
          cb.tool_name,
          COUNT(*) AS usage_count,
          COUNT(DISTINCT m.session_id) AS session_count
        FROM content_blocks cb
        JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
        JOIN messages m ON m.uuid = am.message_uuid
        WHERE cb.block_type = 'tool_use'
        GROUP BY cb.tool_name
        ORDER BY usage_count DESC
      SQL
    },
    {
      label: "Daily token usage (last 30 days)",
      sql: <<~SQL.strip
        SELECT
          DATE(s.created_at) AS day,
          COUNT(DISTINCT s.session_id) AS sessions,
          SUM(am.input_tokens + am.output_tokens) AS tokens
        FROM sessions s
        JOIN messages m ON m.session_id = s.session_id
        JOIN assistant_messages am ON am.message_uuid = m.uuid
        WHERE s.created_at >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY DATE(s.created_at)
        ORDER BY day
      SQL
    },
    {
      label: "Sessions that used the Agent tool",
      sql: <<~SQL.strip
        SELECT
          s.session_id,
          COALESCE(s.custom_title, LEFT(s.last_prompt, 60)) AS title,
          COUNT(*) AS agent_calls,
          s.created_at::date AS date
        FROM sessions s
        JOIN messages m ON m.session_id = s.session_id
        JOIN assistant_messages am ON am.message_uuid = m.uuid
        JOIN content_blocks cb ON cb.assistant_message_uuid = am.message_uuid
        WHERE cb.block_type = 'tool_use' AND cb.tool_name = 'Agent'
        GROUP BY s.session_id, s.custom_title, s.last_prompt, s.created_at
        ORDER BY agent_calls DESC
        LIMIT 20
      SQL
    },
    {
      label: "Average tokens per tool type",
      sql: <<~SQL.strip
        SELECT
          cb.tool_name,
          COUNT(*) AS calls,
          ROUND(AVG(am.input_tokens + am.output_tokens)) AS avg_tokens_per_call
        FROM content_blocks cb
        JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
        WHERE cb.block_type = 'tool_use'
        GROUP BY cb.tool_name
        ORDER BY avg_tokens_per_call DESC
      SQL
    },
  ].freeze

  def index
    @schema = SCHEMA_REFERENCE
    @examples = EXAMPLE_QUERIES
    @sql = params[:sql]&.strip

    if @sql.present?
      execute_sql
    end
  end

  private

  def execute_sql
    error = validate_sql(@sql)
    if error
      @error = error
      return
    end

    query = ensure_limit(@sql)

    ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT_MS}'")
    @results = ActiveRecord::Base.connection.exec_query(query)
    @executed_sql = query
  rescue ActiveRecord::StatementInvalid, PG::Error => e
    @error = e.message.sub(/^PG::.*ERROR:\s*/, "")
  end

  def validate_sql(sql)
    normalized = sql.gsub(/--.*$/, "").gsub(/\/\*.*?\*\//m, "").strip

    return "Query cannot be empty." if normalized.blank?

    unless normalized.match?(/\A\s*SELECT\b/i) || normalized.match?(/\A\s*WITH\b/i)
      return "Only SELECT queries are allowed."
    end

    FORBIDDEN_PATTERNS.each do |pattern|
      if normalized.match?(pattern)
        return "Query contains a forbidden statement. Only SELECT queries are allowed."
      end
    end

    nil
  end

  def ensure_limit(sql)
    if sql.match?(/\bLIMIT\s+\d+/i)
      # Enforce max
      sql.gsub(/\bLIMIT\s+(\d+)/i) do
        "LIMIT #{[Regexp.last_match(1).to_i, MAX_ROWS].min}"
      end
    else
      "#{sql.chomp(';').strip}\nLIMIT #{MAX_ROWS}"
    end
  end
end

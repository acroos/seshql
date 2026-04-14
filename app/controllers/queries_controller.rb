class QueriesController < ApplicationController
  METRICS = {
    "session_count" => { label: "Session Count", sql: "COUNT(DISTINCT sessions.session_id)", requires: [:sessions] },
    "message_count" => { label: "Message Count", sql: "COUNT(DISTINCT messages.uuid)", requires: [:messages] },
    "human_prompt_count" => { label: "Human Prompt Count", sql: "COUNT(DISTINCT user_prompts.message_uuid)", requires: [:messages, :user_prompts] },
    "tool_call_count" => { label: "Tool Call Count", sql: "COUNT(DISTINCT content_blocks.id) FILTER (WHERE content_blocks.block_type = 'tool_use')", requires: [:messages, :assistant_messages, :content_blocks] },
    "tool_result_count" => { label: "Tool Result Count", sql: "COUNT(DISTINCT tool_results.message_uuid)", requires: [:messages, :tool_results] },
    "total_input_tokens" => { label: "Total Input Tokens", sql: "COALESCE(SUM(assistant_messages.input_tokens + assistant_messages.cache_creation_input_tokens + assistant_messages.cache_read_input_tokens), 0)", requires: [:messages, :assistant_messages] },
    "total_output_tokens" => { label: "Total Output Tokens", sql: "COALESCE(SUM(assistant_messages.output_tokens), 0)", requires: [:messages, :assistant_messages] },
    "total_tokens" => { label: "Total Tokens", sql: "COALESCE(SUM(assistant_messages.input_tokens + assistant_messages.output_tokens + assistant_messages.cache_creation_input_tokens + assistant_messages.cache_read_input_tokens), 0)", requires: [:messages, :assistant_messages] },
    "total_duration_s" => { label: "Total Duration", sql: "COALESCE(SUM(system_events.duration_ms) FILTER (WHERE system_events.subtype = 'turn_duration') / 1000, 0)", requires: [:messages, :system_events], format: :duration },
    "avg_tokens_per_session" => { label: "Avg Tokens / Session", sql: "ROUND(COALESCE(SUM(assistant_messages.input_tokens + assistant_messages.output_tokens + assistant_messages.cache_creation_input_tokens + assistant_messages.cache_read_input_tokens), 0)::numeric / NULLIF(COUNT(DISTINCT sessions.session_id), 0), 0)", requires: [:messages, :assistant_messages] },
    "avg_duration_per_session_s" => { label: "Avg Duration / Session", sql: "ROUND(COALESCE(SUM(system_events.duration_ms) FILTER (WHERE system_events.subtype = 'turn_duration'), 0)::numeric / NULLIF(COUNT(DISTINCT sessions.session_id), 0) / 1000, 0)", requires: [:messages, :system_events], format: :duration },
    "assistant_message_count" => { label: "Assistant Message Count", sql: "COUNT(DISTINCT assistant_messages.message_uuid)", requires: [:messages, :assistant_messages] },
    "unique_tool_count" => { label: "Unique Tools Used", sql: "COUNT(DISTINCT content_blocks.tool_name) FILTER (WHERE content_blocks.block_type = 'tool_use')", requires: [:messages, :assistant_messages, :content_blocks] },
    "pr_count" => { label: "PR Count", sql: "COUNT(DISTINCT pr_links.id)", requires: [:pr_links] }
  }.freeze

  DIMENSIONS = {
    "session" => { label: "Session", sql: "sessions.session_id", display_sql: "COALESCE(sessions.custom_title, LEFT(sessions.last_prompt, 80), sessions.session_id)", requires: [:sessions] },
    "project" => { label: "Project", sql: "REGEXP_REPLACE(sessions.project_path, '--claude-worktrees-.*$', '')", requires: [:sessions] },
    "project_detailed" => { label: "Project (with worktrees)", sql: "sessions.project_path", requires: [:sessions] },
    "model" => { label: "Model", sql: "assistant_messages.model", requires: [:messages, :assistant_messages] },
    "tool_name" => { label: "Tool Name", sql: "content_blocks.tool_name", requires: [:messages, :assistant_messages, :content_blocks], where: "content_blocks.block_type = 'tool_use'" },
    "date" => { label: "Date (day)", sql: "DATE(sessions.created_at)", requires: [:sessions] },
    "week" => { label: "Date (week)", sql: "DATE_TRUNC('week', sessions.created_at)::date", requires: [:sessions] },
    "month" => { label: "Date (month)", sql: "TO_CHAR(sessions.created_at, 'YYYY-MM')", requires: [:sessions] },
    "git_branch" => { label: "Git Branch", sql: "messages.git_branch", requires: [:messages] },
    "entrypoint" => { label: "Entrypoint", sql: "messages.entrypoint", requires: [:messages] },
    "stop_reason" => { label: "Stop Reason", sql: "assistant_messages.stop_reason", requires: [:messages, :assistant_messages] },
    "permission_mode" => { label: "Permission Mode", sql: "sessions.permission_mode", requires: [:sessions] },
    "agent_name" => { label: "Agent Name", sql: "sessions.agent_name", requires: [:sessions] }
  }.freeze

  FILTERS = {
    "project" => { label: "Project", column: "sessions.project_path", type: :project },
    "date_from" => { label: "Date From", column: "sessions.created_at", type: :date_gte },
    "date_to" => { label: "Date To", column: "sessions.created_at", type: :date_lte },
    "model" => { label: "Model", column: "assistant_messages.model", type: :select, requires: [:messages, :assistant_messages] },
    "tool_name" => { label: "Tool Name", column: "content_blocks.tool_name", type: :select, requires: [:messages, :assistant_messages, :content_blocks] },
    "search" => { label: "Text Search", column: nil, type: :search }
  }.freeze

  SORT_DIRECTIONS = %w[desc asc].freeze

  def index
    @metrics = METRICS
    @dimensions = DIMENSIONS
    @filters = FILTERS
    @models = AssistantMessage.distinct.where.not(model: nil).pluck(:model).sort
    @tools = ContentBlock.where(block_type: :tool_use).distinct.where.not(tool_name: nil).pluck(:tool_name).sort
    @projects = Session.base_project_paths

    if params[:metrics].present?
      execute_query
    end
  end

  private

  def execute_query
    selected_metrics = Array(params[:metrics]).select { |m| METRICS.key?(m) }
    selected_dimensions = Array(params[:dimensions]).select { |d| DIMENSIONS.key?(d) }
    sort_dir = SORT_DIRECTIONS.include?(params[:sort_dir]) ? params[:sort_dir] : "desc"
    sort_by = params[:sort_by].present? ? params[:sort_by].to_i : selected_dimensions.size
    limit = [[params.fetch(:limit, 50).to_i, 1].max, 500].min

    return if selected_metrics.empty?

    # Gather all required joins
    required_joins = Set.new([:sessions])
    extra_wheres = []

    (selected_metrics + selected_dimensions).each do |key|
      config = METRICS[key] || DIMENSIONS[key]
      next unless config
      required_joins.merge(config[:requires]) if config[:requires]
    end

    # Only dimension wheres go into the global WHERE (metric wheres use FILTER)
    selected_dimensions.each do |key|
      dim = DIMENSIONS[key]
      extra_wheres << dim[:where] if dim&.dig(:where)
    end

    # Build filter conditions
    filter_conditions = []
    filter_binds = {}
    filters = params[:filters].respond_to?(:dig) ? params[:filters] : {}

    if filters.dig(:project).present?
      base = filters[:project]
      required_joins << :sessions
      filter_conditions << "(sessions.project_path = :fp OR sessions.project_path LIKE :fwt)"
      filter_binds[:fp] = base
      filter_binds[:fwt] = "#{base}--claude-worktrees-%"
    end

    if filters.dig( :date_from).present?
      required_joins << :sessions
      filter_conditions << "sessions.created_at >= :date_from"
      filter_binds[:date_from] = filters[:date_from]
    end

    if filters.dig( :date_to).present?
      required_joins << :sessions
      filter_conditions << "sessions.created_at <= :date_to"
      filter_binds[:date_to] = "#{filters[:date_to]} 23:59:59"
    end

    if filters.dig( :model).present?
      required_joins.merge([:messages, :assistant_messages])
      filter_conditions << "assistant_messages.model = :model_filter"
      filter_binds[:model_filter] = filters[:model]
    end

    if filters.dig( :tool_name).present?
      required_joins.merge([:messages, :assistant_messages, :content_blocks])
      filter_conditions << "content_blocks.tool_name = :tool_filter"
      filter_binds[:tool_filter] = filters[:tool_name]
    end

    if filters.dig( :search).present?
      required_joins.merge([:messages, :user_prompts])
      filter_conditions << "(user_prompts.content_text ILIKE :search OR sessions.custom_title ILIKE :search)"
      filter_binds[:search] = "%#{filters[:search]}%"
    end

    # Build SQL
    select_parts = []
    group_parts = []

    selected_dimensions.each do |dim_key|
      dim = DIMENSIONS[dim_key]
      if dim[:display_sql]
        select_parts << "#{dim[:display_sql]} AS #{dim_key}"
        group_parts << dim[:display_sql]
        group_parts << dim[:sql]
      else
        select_parts << "#{dim[:sql]} AS #{dim_key}"
        group_parts << dim[:sql]
      end
    end

    selected_metrics.each do |met_key|
      met = METRICS[met_key]
      select_parts << "#{met[:sql]} AS #{met_key}"
    end

    query = "SELECT #{select_parts.join(', ')} FROM sessions"
    query += join_clause(required_joins)

    all_conditions = extra_wheres + filter_conditions
    if all_conditions.any?
      query += " WHERE #{all_conditions.join(' AND ')}"
    end

    if group_parts.any?
      query += " GROUP BY #{group_parts.join(', ')}"
    end

    # Sort
    sort_index = sort_by
    all_columns = selected_dimensions + selected_metrics
    sort_col = all_columns[sort_index] || selected_metrics.first
    query += " ORDER BY #{sort_col} #{sort_dir} NULLS LAST"
    query += " LIMIT #{limit}"

    @results = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql([query, filter_binds])
    )

    @column_headers = selected_dimensions.map { |d|
      { key: d, label: DIMENSIONS[d][:label] }
    } + selected_metrics.map { |m| { key: m, label: METRICS[m][:label], format: METRICS[m][:format] } }

    @selected_metrics = selected_metrics
    @selected_dimensions = selected_dimensions
  end

  def join_clause(required)
    sql = ""
    if required.include?(:messages)
      sql += " LEFT JOIN messages ON messages.session_id = sessions.session_id"
    end
    if required.include?(:user_prompts)
      sql += " LEFT JOIN user_prompts ON user_prompts.message_uuid = messages.uuid"
    end
    if required.include?(:tool_results)
      sql += " LEFT JOIN tool_results ON tool_results.message_uuid = messages.uuid"
    end
    if required.include?(:assistant_messages)
      sql += " LEFT JOIN assistant_messages ON assistant_messages.message_uuid = messages.uuid"
    end
    if required.include?(:content_blocks)
      sql += " LEFT JOIN content_blocks ON content_blocks.assistant_message_uuid = assistant_messages.message_uuid"
    end
    if required.include?(:system_events)
      sql += " LEFT JOIN system_events ON system_events.message_uuid = messages.uuid"
    end
    if required.include?(:pr_links)
      sql += " LEFT JOIN pr_links ON pr_links.session_id = sessions.session_id"
    end
    sql
  end
end

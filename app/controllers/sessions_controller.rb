class SessionsController < ApplicationController
  def index
    @sessions = Session.recent
    if params[:project].present?
      @sessions = @sessions.where("project_path = :p OR project_path LIKE :wt",
        p: params[:project], wt: "#{params[:project]}--claude-worktrees-%")
    end

    if params[:q].present?
      q = "%#{params[:q]}%"
      @sessions = @sessions.where(
        "custom_title ILIKE :q OR last_prompt ILIKE :q OR session_id ILIKE :q",
        q: q
      )
    end

    @sessions = @sessions.page(params[:page])
    @projects = Session.base_project_paths
  end

  def show
    @session = Session.find(params[:id])
    @messages = @session.messages.main_chain.chronological
      .includes(:user_prompt, :tool_result, { assistant_message: :content_blocks }, :system_event, :attachment)
    @tool_results_by_use_id = @messages
      .filter_map(&:tool_result)
      .index_by(&:tool_use_id)
    @tool_usage = @session.tool_usage_summary
    @total_input = @session.total_input_tokens
    @total_output = @session.total_output_tokens
    @duration_ms = @session.system_events.where(subtype: "turn_duration").sum(:duration_ms)
  end
end

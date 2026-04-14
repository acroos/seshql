class PanelsController < ApplicationController
  before_action :set_dashboard
  before_action :set_panel, only: [ :edit, :update, :destroy, :preview ]

  def new
    @panel = @dashboard.panels.build(chart_type: "bar")
    @schema = SqlConsoleController::SCHEMA_REFERENCE
  end

  def create
    @panel = @dashboard.panels.build(panel_params)
    @panel.position = @dashboard.panels.maximum(:position).to_i + 1

    if @panel.save
      redirect_to @dashboard
    else
      @schema = SqlConsoleController::SCHEMA_REFERENCE
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @schema = SqlConsoleController::SCHEMA_REFERENCE
  end

  def update
    if @panel.update(panel_params)
      redirect_to @dashboard
    else
      @schema = SqlConsoleController::SCHEMA_REFERENCE
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @panel.destroy
    redirect_to @dashboard
  end

  def preview
    result = @panel.assign_attributes(panel_params) if params[:dashboard_panel].present?
    result = @panel.execute_query
    render json: result[:chart_data] || { error: result[:error] }
  end

  private

  def set_dashboard
    @dashboard = Dashboard.find(params[:dashboard_id])
  end

  def set_panel
    @panel = @dashboard.panels.find(params[:id])
  end

  def panel_params
    permitted = params.require(:dashboard_panel).permit(:title, :sql_query, :chart_type, :x_column, :series_column, :value_column,
      :config_secondary_y_datasets, :config_y_axis_label, :config_y1_axis_label)

    # Build config JSONB from the config_ prefixed params
    config = {}
    if permitted[:config_secondary_y_datasets].present?
      config["secondary_y_datasets"] = permitted[:config_secondary_y_datasets].split(",").map(&:strip).reject(&:blank?)
    end
    config["y_axis_label"] = permitted[:config_y_axis_label] if permitted[:config_y_axis_label].present?
    config["y1_axis_label"] = permitted[:config_y1_axis_label] if permitted[:config_y1_axis_label].present?

    permitted.except(:config_secondary_y_datasets, :config_y_axis_label, :config_y1_axis_label).merge(config: config)
  end
end

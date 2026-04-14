class DashboardsController < ApplicationController
  before_action :set_dashboard, only: [ :show, :edit, :update, :destroy ]

  def index
    @dashboards = Dashboard.order(updated_at: :desc)
  end

  def show
    @panels_data = @dashboard.panels.order(:position).map do |panel|
      result = panel.execute_query
      { panel: panel, **result }
    end
  end

  def new
    @dashboard = Dashboard.new
  end

  def create
    @dashboard = Dashboard.new(dashboard_params)
    if @dashboard.save
      redirect_to @dashboard
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @dashboard.update(dashboard_params)
      redirect_to @dashboard
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @dashboard.destroy
    redirect_to dashboards_path
  end

  private

  def set_dashboard
    @dashboard = Dashboard.find(params[:id])
  end

  def dashboard_params
    params.require(:dashboard).permit(:name, :description)
  end
end

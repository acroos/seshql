Rails.application.routes.draw do
  root "dashboards#index"

  resources :sessions, only: [ :index, :show ]
  resources :sql_console, only: [ :index ]
  resources :ingestion_runs, only: [ :index ] do
    member { post :retry }
  end

  resources :dashboards do
    resources :panels, only: [ :new, :create, :edit, :update, :destroy ]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end

Rails.application.routes.draw do
  root "dashboard#index"

  resources :sessions, only: [ :index, :show ]
  resources :queries, only: [ :index ]
  resources :sql_console, only: [ :index ]

  resources :dashboards do
    resources :panels, only: [ :new, :create, :edit, :update, :destroy ]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end

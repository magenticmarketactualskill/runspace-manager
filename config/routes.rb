Rails.application.routes.draw do
  # Dashboard
  resource :dashboard, only: [:show], controller: "dashboard" do
    post :refresh_health, on: :member
  end

  # Resources
  resources :mcp_servers do
    member do
      post :connect
      post :disconnect
      post :refresh_capabilities
    end
  end

  resources :skills do
    member do
      post :execute
      post :register
      post :unregister
    end
  end

  resources :shared_gems do
    member do
      post :check_status
      post :install
      post :build
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Root path - Dashboard
  root "dashboard#index"
end

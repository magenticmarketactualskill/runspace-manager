# frozen_string_literal: true

class SharedGemsController < ApplicationController
  before_action :set_shared_gem, only: %i[show edit update destroy check_status install build]

  def index
    @shared_gems = SharedGem.all.order(:name)
  end

  def show
  end

  def new
    @shared_gem = SharedGem.new
  end

  def edit
  end

  def create
    @shared_gem = SharedGem.new(shared_gem_params)

    if @shared_gem.save
      redirect_to @shared_gem, notice: "Gem was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @shared_gem.update(shared_gem_params)
      redirect_to @shared_gem, notice: "Gem was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @shared_gem.destroy!
    redirect_to shared_gems_url, notice: "Gem was successfully deleted."
  end

  # Custom actions

  def check_status
    @shared_gem.check_status!
    redirect_to @shared_gem, notice: "Status checked: #{@shared_gem.status}"
  end

  def install
    return redirect_to(@shared_gem, alert: "No local path configured") unless @shared_gem.local_path.present?

    begin
      # Run bundle install in the gem directory
      output = `cd #{@shared_gem.local_path} && bundle install 2>&1`
      success = $?.success?

      if success
        @shared_gem.update!(status: "installed", last_check_at: Time.current, last_error: nil)
        redirect_to @shared_gem, notice: "Dependencies installed successfully."
      else
        @shared_gem.update!(status: "error", last_error: output.last(500))
        redirect_to @shared_gem, alert: "Install failed. Check logs."
      end
    rescue StandardError => e
      @shared_gem.update!(status: "error", last_error: e.message)
      redirect_to @shared_gem, alert: "Install failed: #{e.message}"
    end
  end

  def build
    return redirect_to(@shared_gem, alert: "No local path configured") unless @shared_gem.local_path.present?

    begin
      # Find gemspec
      gemspec = Dir.glob(File.join(@shared_gem.local_path, "*.gemspec")).first
      return redirect_to(@shared_gem, alert: "No gemspec found") unless gemspec

      # Build the gem
      output = `cd #{@shared_gem.local_path} && gem build #{File.basename(gemspec)} 2>&1`
      success = $?.success?

      if success
        @shared_gem.update!(
          status: "installed",
          last_check_at: Time.current,
          last_error: nil,
          built_at: Time.current
        )
        redirect_to @shared_gem, notice: "Gem built successfully."
      else
        @shared_gem.update!(status: "error", last_error: output.last(500))
        redirect_to @shared_gem, alert: "Build failed. Check logs."
      end
    rescue StandardError => e
      @shared_gem.update!(status: "error", last_error: e.message)
      redirect_to @shared_gem, alert: "Build failed: #{e.message}"
    end
  end

  private

  def set_shared_gem
    @shared_gem = SharedGem.find(params[:id])
  end

  def shared_gem_params
    params.require(:shared_gem).permit(
      :name, :version, :local_path, :repository_url,
      :status, :description, dependencies: []
    )
  end
end

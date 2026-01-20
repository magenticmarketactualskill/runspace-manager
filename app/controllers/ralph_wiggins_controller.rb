# frozen_string_literal: true

class RalphWigginsController < ApplicationController
  before_action :set_epoch, only: [:show_epoch, :start_epoch, :stop_epoch, :pause_epoch, :resume_epoch, :destroy_epoch]

  def index
    @ralph = RalphWiggins.current
    @running = RalphWiggins.any_running?
    @epochs = Epoch.all
    @running_epochs = Epoch.running
    @command_history = RalphWiggins.command_history(limit: 25)
  end

  def show
    @ralph = RalphWiggins.current
    @status = @ralph.status
    @epochs = Epoch.all
    @running_epochs = Epoch.running
    @iteration_logs = @ralph.iteration_logs
    @main_log = @ralph.main_log_content(lines: 200)
  end

  def new
    @ralph = RalphWiggins.new
    @default_name = "Epoch #{Time.now.strftime('%Y-%m-%d %H:%M')}"
    @default_prompt = ""
    @default_max_iterations = 10
    @default_completion_marker = "RALPH_DONE"
    @default_working_dir = File.expand_path("~/Documents/RunSpace")
  end

  # Create a new Epoch (without starting)
  def create
    epoch = Epoch.create(
      name: params[:name].presence || "Epoch #{Time.now.strftime('%Y-%m-%d %H:%M')}",
      prompt: params[:prompt],
      max_iterations: params[:max_iterations].presence&.to_i,
      completion_marker: params[:completion_marker].presence || "RALPH_DONE",
      working_dir: params[:working_dir].presence || File.expand_path("~/Documents/RunSpace")
    )

    if epoch.valid?
      if params[:start_immediately] == "1"
        result = epoch.start!
        if result[:success]
          redirect_to ralph_wiggins_index_path, notice: "Epoch '#{epoch.name}' created and started (PID: #{result[:pid]})"
        else
          redirect_to ralph_wiggins_index_path, alert: "Epoch created but failed to start: #{result[:error]}"
        end
      else
        redirect_to ralph_wiggins_index_path, notice: "Epoch '#{epoch.name}' created"
      end
    else
      redirect_to new_ralph_wiggins_path, alert: "Failed to create epoch: #{epoch.errors.full_messages.join(', ')}"
    end
  end

  # Legacy start - creates and starts an epoch
  def start
    @ralph = RalphWiggins.new

    result = @ralph.start(
      name: params[:name].presence,
      prompt: params[:prompt],
      max_iterations: params[:max_iterations].presence&.to_i,
      completion_marker: params[:completion_marker].presence || "RALPH_DONE",
      working_dir: params[:working_dir].presence || File.expand_path("~/Documents/RunSpace")
    )

    if result[:success]
      redirect_to ralph_wiggins_index_path, notice: "Epoch '#{result[:epoch].name}' started (PID: #{result[:pid]})"
    else
      redirect_to new_ralph_wiggins_path, alert: "Failed to start: #{result[:error]}"
    end
  end

  # Stop all running epochs
  def stop
    results = RalphWiggins.stop_all_epochs

    if results.any?
      redirect_to ralph_wiggins_index_path, notice: "Stopped #{results.count} epoch(s)"
    else
      redirect_to ralph_wiggins_index_path, alert: "No running epochs to stop"
    end
  end

  def status
    @ralph = RalphWiggins.current
    @status = @ralph.status

    respond_to do |format|
      format.html { render :show }
      format.json { render json: @status }
    end
  end

  def logs
    @ralph = RalphWiggins.current
    @main_log = @ralph.main_log_content(lines: 500)
    @iteration_logs = @ralph.iteration_logs
  end

  def command_history
    @command_history = RalphWiggins.command_history(limit: 100)

    respond_to do |format|
      format.html
      format.json { render json: @command_history }
    end
  end

  # Epoch-specific actions
  def epochs
    @epochs = Epoch.all
    @running_epochs = Epoch.running

    respond_to do |format|
      format.html
      format.json { render json: @epochs.map(&:to_h) }
    end
  end

  def show_epoch
    @iteration_logs = @epoch.iteration_logs
    @main_log = @epoch.main_log_content(lines: 200)
    @facts = @epoch.facts
  end

  def start_epoch
    result = @epoch.start!

    if result[:success]
      redirect_to ralph_wiggins_index_path, notice: "Epoch '#{@epoch.name}' started (PID: #{result[:pid]})"
    else
      redirect_to ralph_wiggins_index_path, alert: "Failed to start epoch: #{result[:error]}"
    end
  end

  def stop_epoch
    result = @epoch.stop!

    if result[:success]
      redirect_to ralph_wiggins_index_path, notice: "Epoch '#{@epoch.name}' stopped"
    else
      redirect_to ralph_wiggins_index_path, alert: "Failed to stop epoch: #{result[:error]}"
    end
  end

  def pause_epoch
    result = @epoch.pause!

    if result[:success]
      redirect_to ralph_wiggins_index_path, notice: "Epoch '#{@epoch.name}' paused"
    else
      redirect_to ralph_wiggins_index_path, alert: "Failed to pause epoch: #{result[:error]}"
    end
  end

  def resume_epoch
    result = @epoch.resume!

    if result[:success]
      redirect_to ralph_wiggins_index_path, notice: "Epoch '#{@epoch.name}' resumed"
    else
      redirect_to ralph_wiggins_index_path, alert: "Failed to resume epoch: #{result[:error]}"
    end
  end

  def destroy_epoch
    name = @epoch.name
    @epoch.stop! if @epoch.running?
    @epoch.destroy

    redirect_to ralph_wiggins_index_path, notice: "Epoch '#{name}' deleted"
  end

  private

  def set_epoch
    @epoch = Epoch.find(params[:id] || params[:epoch_id])
    unless @epoch
      redirect_to ralph_wiggins_index_path, alert: "Epoch not found"
    end
  end
end

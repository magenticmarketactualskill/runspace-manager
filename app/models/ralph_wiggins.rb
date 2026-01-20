# frozen_string_literal: true

# RalphWiggins - Manager for parallel Epochs (autonomous loop runners)
# Reads and writes to ~/Documents/RunSpace/.ralph_wiggins
# Epochs are Entities that represent parallel execution contexts
class RalphWiggins
  RALPH_DIR = File.expand_path("~/Documents/RunSpace/.ralph_wiggins")
  STATE_FILE = File.join(RALPH_DIR, "state.json")
  COMMAND_LOG = File.join(RALPH_DIR, "command_log.jsonl")
  SESSIONS_DIR = File.join(RALPH_DIR, "sessions")

  STATUSES = %w[running stopped completed max_iterations_reached error].freeze

  attr_reader :state

  class << self
    def current
      new.tap(&:load_state)
    end

    # Legacy single-run check (deprecated - use epochs instead)
    def running?
      instance = current
      instance.state["status"] == "running" && instance.process_alive?
    end

    # Epoch management class methods
    def epochs
      Epoch.all
    end

    def running_epochs
      Epoch.running
    end

    def active_epochs
      Epoch.active
    end

    def find_epoch(id)
      Epoch.find(id)
    end

    def any_running?
      Epoch.running.any?
    end

    def running_count
      Epoch.running.count
    end

    def command_history(limit: 50)
      return [] unless File.exist?(COMMAND_LOG)

      lines = File.readlines(COMMAND_LOG).last(limit)
      lines.map { |line| JSON.parse(line) }
    rescue JSON::ParserError
      []
    end

    def sessions
      return [] unless Dir.exist?(SESSIONS_DIR)

      Dir.glob(File.join(SESSIONS_DIR, "*.json")).map do |file|
        JSON.parse(File.read(file))
      end.sort_by { |s| s["started_at"] || "" }.reverse
    rescue JSON::ParserError
      []
    end

    # Create and start a new Epoch
    def create_epoch(name:, prompt:, max_iterations: nil, completion_marker: "RALPH_DONE", working_dir: nil)
      working_dir ||= File.expand_path("~/Documents/RunSpace")

      epoch = Epoch.create(
        name: name,
        prompt: prompt,
        max_iterations: max_iterations,
        completion_marker: completion_marker,
        working_dir: working_dir
      )

      log_command("create_epoch", {
        epoch_id: epoch.id,
        name: name,
        prompt: prompt.truncate(100),
        max_iterations: max_iterations
      })

      epoch
    end

    def start_epoch(epoch_or_id)
      epoch = epoch_or_id.is_a?(Epoch) ? epoch_or_id : Epoch.find(epoch_or_id)
      return { success: false, error: "Epoch not found" } unless epoch

      log_command("start_epoch", { epoch_id: epoch.id, name: epoch.name })
      epoch.start!
    end

    def stop_epoch(epoch_or_id)
      epoch = epoch_or_id.is_a?(Epoch) ? epoch_or_id : Epoch.find(epoch_or_id)
      return { success: false, error: "Epoch not found" } unless epoch

      log_command("stop_epoch", { epoch_id: epoch.id, name: epoch.name })
      epoch.stop!
    end

    def stop_all_epochs
      stopped = []
      Epoch.running.each do |epoch|
        result = stop_epoch(epoch)
        stopped << { epoch_id: epoch.id, result: result }
      end
      log_command("stop_all_epochs", { stopped_count: stopped.count })
      stopped
    end

    def pause_epoch(epoch_or_id)
      epoch = epoch_or_id.is_a?(Epoch) ? epoch_or_id : Epoch.find(epoch_or_id)
      return { success: false, error: "Epoch not found" } unless epoch

      log_command("pause_epoch", { epoch_id: epoch.id })
      epoch.pause!
    end

    def resume_epoch(epoch_or_id)
      epoch = epoch_or_id.is_a?(Epoch) ? epoch_or_id : Epoch.find(epoch_or_id)
      return { success: false, error: "Epoch not found" } unless epoch

      log_command("resume_epoch", { epoch_id: epoch.id })
      epoch.resume!
    end

    def destroy_epoch(epoch_or_id)
      epoch = epoch_or_id.is_a?(Epoch) ? epoch_or_id : Epoch.find(epoch_or_id)
      return { success: false, error: "Epoch not found" } unless epoch

      epoch.stop! if epoch.running?
      log_command("destroy_epoch", { epoch_id: epoch.id, name: epoch.name })
      epoch.destroy
      { success: true }
    end

    private

    def log_command(command, params)
      ensure_directories
      entry = {
        timestamp: Time.now.iso8601,
        command: command,
        params: params
      }
      File.open(COMMAND_LOG, "a") { |f| f.puts(entry.to_json) }
    end

    def ensure_directories
      FileUtils.mkdir_p(RALPH_DIR)
      FileUtils.mkdir_p(SESSIONS_DIR)
    end
  end

  def initialize
    @state = default_state
    ensure_directories
  end

  def load_state
    return unless File.exist?(STATE_FILE)

    @state = JSON.parse(File.read(STATE_FILE))
  rescue JSON::ParserError
    @state = default_state
  end

  def save_state
    File.write(STATE_FILE, JSON.pretty_generate(@state))
  end

  # Legacy start method - now creates and starts an Epoch
  def start(prompt:, max_iterations: nil, completion_marker: "RALPH_DONE", working_dir: nil, name: nil)
    name ||= "Run #{Time.now.strftime('%Y-%m-%d %H:%M')}"

    epoch = self.class.create_epoch(
      name: name,
      prompt: prompt,
      max_iterations: max_iterations,
      completion_marker: completion_marker,
      working_dir: working_dir
    )

    result = epoch.start!

    if result[:success]
      @state = {
        "pid" => epoch.pid,
        "status" => "running",
        "started_at" => epoch.started_at&.iso8601,
        "iteration" => 0,
        "prompt" => prompt,
        "max_iterations" => max_iterations,
        "completion_marker" => completion_marker,
        "working_dir" => working_dir,
        "current_epoch_id" => epoch.id
      }
      save_state
    end

    result.merge(epoch_id: epoch.id, epoch: epoch)
  end

  # Legacy stop method - stops current epoch or all running epochs
  def stop
    if @state["current_epoch_id"]
      epoch = Epoch.find(@state["current_epoch_id"])
      if epoch
        result = epoch.stop!
        @state["status"] = "stopped"
        @state["stopped_at"] = Time.now.iso8601
        save_state
        return result
      end
    end

    # Fall back to stopping all running epochs
    self.class.stop_all_epochs
    @state["status"] = "stopped"
    save_state
    { success: true }
  end

  def status
    load_state

    {
      running: process_alive?,
      state: @state,
      epochs: {
        total: Epoch.all.count,
        running: Epoch.running.count,
        active: Epoch.active.count
      },
      running_epochs: Epoch.running.map(&:to_h),
      command_history: self.class.command_history(limit: 10)
    }
  end

  def process_alive?
    return false unless @state["pid"]

    Process.kill(0, @state["pid"].to_i)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def status_color
    return "green" if Epoch.running.any?

    case @state["status"]
    when "running" then "green"
    when "completed" then "blue"
    when "stopped" then "gray"
    when "max_iterations_reached" then "yellow"
    when "error" then "red"
    else "gray"
    end
  end

  def current_epoch
    return nil unless @state["current_epoch_id"]

    Epoch.find(@state["current_epoch_id"])
  end

  def iteration_logs
    epoch = current_epoch
    return epoch.iteration_logs if epoch

    return [] unless @state["working_dir"]

    logs_dir = File.join(@state["working_dir"], "tmp")
    return [] unless Dir.exist?(logs_dir)

    Dir.glob(File.join(logs_dir, "ralph_iteration_*.log")).sort.map do |file|
      {
        iteration: File.basename(file, ".log").sub("ralph_iteration_", "").to_i,
        path: file,
        size: File.size(file),
        content: File.read(file).truncate(5000)
      }
    end
  end

  def main_log_content(lines: 100)
    epoch = current_epoch
    return epoch.main_log_content(lines: lines) if epoch

    log_file = File.join(@state["working_dir"] || File.expand_path("~/Documents/RunSpace"), "log/ralph_wiggins.log")
    return "" unless File.exist?(log_file)

    File.readlines(log_file).last(lines).join
  end

  private

  def ensure_directories
    FileUtils.mkdir_p(RALPH_DIR)
    FileUtils.mkdir_p(SESSIONS_DIR)
  end

  def default_state
    {
      "pid" => nil,
      "status" => "stopped",
      "started_at" => nil,
      "stopped_at" => nil,
      "iteration" => 0,
      "prompt" => nil,
      "max_iterations" => nil,
      "completion_marker" => "RALPH_DONE",
      "working_dir" => nil,
      "current_epoch_id" => nil
    }
  end

  def log_command(command, params)
    self.class.send(:log_command, command, params)
  end

  def save_session(session_id, data)
    session_file = File.join(SESSIONS_DIR, "#{session_id}.json")
    File.write(session_file, JSON.pretty_generate(data))
  end
end

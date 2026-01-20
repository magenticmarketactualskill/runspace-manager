# frozen_string_literal: true

require_relative "ralph_wiggins/life_cycle"
require_relative "kanban/client"
require_relative "kanban/board_link"

# Epoch - A parallel execution context for RalphWiggins
# Epochs are Entities (see entity_knowledge gem) that represent autonomous loop runs
# Each Epoch tracks its own state, prompt, iterations, and can run in parallel
# Links to CollaborativeKanban board for task tracking
class Epoch
  include ActiveModel::Model
  include ActiveModel::Attributes
  include RalphWiggins::LifeCycle::EpochIntegration

  EPOCH_DIR = File.join(RalphWiggins::RALPH_DIR, "epochs")
  STATUSES = %w[pending running paused completed failed max_iterations_reached stopped].freeze
  ENTITY_TYPE = "Epoch"

  # Entity-like attributes
  attribute :id, :string
  attribute :name, :string
  attribute :entity_type, :string, default: ENTITY_TYPE
  attribute :confidence, :float, default: 1.0
  attribute :aliases, default: -> { [] }
  attribute :external_id, :string
  attribute :metadata, default: -> { {} }

  # Epoch-specific attributes
  attribute :status, :string, default: "pending"
  attribute :prompt, :string
  attribute :max_iterations, :integer
  attribute :completion_marker, :string, default: "RALPH_DONE"
  attribute :working_dir, :string
  attribute :iteration, :integer, default: 0
  attribute :pid, :integer
  attribute :started_at, :datetime
  attribute :stopped_at, :datetime
  attribute :completed_at, :datetime
  attribute :last_error, :string
  attribute :facts, default: -> { [] }

  # Kanban integration
  attribute :kanban_card_id, :integer
  attribute :kanban_synced_at, :datetime

  validates :name, presence: true
  validates :prompt, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  class << self
    def all
      ensure_directory
      Dir.glob(File.join(EPOCH_DIR, "*.json")).map do |file|
        from_file(file)
      end.compact.sort_by { |e| e.started_at || Time.at(0) }.reverse
    end

    def find(id)
      file = File.join(EPOCH_DIR, "#{id}.json")
      return nil unless File.exist?(file)

      from_file(file)
    end

    def running
      all.select(&:running?)
    end

    def active
      all.select { |e| %w[pending running paused].include?(e.status) }
    end

    def completed
      all.select { |e| %w[completed failed max_iterations_reached stopped].include?(e.status) }
    end

    def create(attributes = {})
      epoch = new(attributes)
      epoch.id ||= generate_id
      epoch.save
      epoch
    end

    def generate_id
      "epoch_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(4)}"
    end

    private

    def ensure_directory
      FileUtils.mkdir_p(EPOCH_DIR)
    end

    def from_file(file)
      data = JSON.parse(File.read(file))
      new(data.transform_keys(&:to_sym))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end
  end

  def initialize(attributes = {})
    super
    self.class.send(:ensure_directory)
  end

  def save
    return false unless valid?

    File.write(file_path, to_json)
    true
  end

  def destroy
    FileUtils.rm_f(file_path)
    FileUtils.rm_rf(epoch_dir) if Dir.exist?(epoch_dir)
    true
  end

  def file_path
    File.join(EPOCH_DIR, "#{id}.json")
  end

  def epoch_dir
    File.join(EPOCH_DIR, id)
  end

  def log_dir
    File.join(epoch_dir, "logs")
  end

  def to_json(*_args)
    JSON.pretty_generate(to_h)
  end

  def to_h
    {
      id: id,
      name: name,
      entity_type: entity_type,
      confidence: confidence,
      aliases: aliases,
      external_id: external_id,
      metadata: metadata,
      status: status,
      prompt: prompt,
      max_iterations: max_iterations,
      completion_marker: completion_marker,
      working_dir: working_dir,
      iteration: iteration,
      pid: pid,
      started_at: started_at&.iso8601,
      stopped_at: stopped_at&.iso8601,
      completed_at: completed_at&.iso8601,
      last_error: last_error,
      facts: facts,
      kanban_card_id: kanban_card_id,
      kanban_synced_at: kanban_synced_at&.iso8601
    }
  end

  # Entity-like methods
  def add_alias(alias_name)
    self.aliases = (aliases || []) + [alias_name]
    self.aliases.uniq!
  end

  def all_names
    [name] + (aliases || [])
  end

  def ai_extracted?
    confidence < 1.0
  end

  def needs_review?
    ai_extracted? && confidence < 0.8
  end

  def icon
    "🔄"
  end

  # Kanban integration methods
  # ALL Epoch cards MUST use the RunSpaceManager board in CollaborativeKanban

  # Check if the RunSpaceManager board exists
  def self.kanban_board_exists?
    Kanban::BoardLink.board_exists?
  end

  # Create the RunSpaceManager board if it doesn't exist
  def self.ensure_kanban_board!
    Kanban::BoardLink.ensure_board!
  end

  # Create the RunSpaceManager board (explicit creation)
  def self.create_kanban_board!
    Kanban::BoardLink.create_board!
  end

  # Check Kanban board status
  def self.kanban_board_status
    Kanban::BoardLink.check_board
  end

  # Instance method to check board exists before syncing
  def kanban_board_exists?
    self.class.kanban_board_exists?
  end

  # Instance method to ensure board exists
  def ensure_kanban_board!
    self.class.ensure_kanban_board!
  end

  # Sync this epoch to the RunSpaceManager Kanban board
  # Will create the board if it doesn't exist
  def sync_to_kanban
    return nil unless Kanban::BoardLink.connected?

    # Ensure the RunSpaceManager board exists before syncing
    begin
      ensure_kanban_board!
    rescue Kanban::BoardLink::BoardNotFoundError, Kanban::BoardLink::BoardCreationError => e
      Rails.logger.warn "Epoch#sync_to_kanban: Cannot ensure board - #{e.message}"
      return nil
    end

    card = Kanban::BoardLink.sync_epoch(self)
    if card
      self.kanban_card_id = card["id"]
      self.kanban_synced_at = Time.current
      save
    end
    card
  end

  def kanban_card
    return nil unless kanban_card_id && Kanban::BoardLink.board_id

    Kanban::BoardLink.client.find_card(Kanban::BoardLink.board_id, kanban_card_id)
  rescue Kanban::Client::Error
    nil
  end

  def kanban_linked?
    kanban_card_id.present?
  end

  def kanban_url
    return nil unless kanban_linked? && Kanban::BoardLink.board_id

    "#{Kanban::Client::DEFAULT_BASE_URL}/boards/#{Kanban::BoardLink.board_id}/cards/#{kanban_card_id}"
  end

  # Get the RunSpaceManager board ID (convenience method)
  def kanban_board_id
    Kanban::BoardLink.board_id
  end

  # Epoch execution methods
  def running?
    status == "running" && process_alive?
  end

  def process_alive?
    return false unless pid

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def start!
    return { success: false, error: "Already running" } if running?
    return { success: false, error: "Invalid epoch" } unless valid?

    FileUtils.mkdir_p(log_dir)

    self.started_at = Time.current
    self.status = "running"
    self.iteration = 0

    # Fork the epoch runner process
    epoch_pid = fork do
      Process.setsid
      $stdin.reopen("/dev/null")
      $stdout.reopen(main_log_path, "a")
      $stderr.reopen($stdout)
      $stdout.sync = true

      run_loop
    end

    Process.detach(epoch_pid)
    self.pid = epoch_pid
    save

    log_fact("started", "Epoch started with PID #{epoch_pid}")
    lifecycle_start!
    sync_to_kanban

    { success: true, pid: epoch_pid }
  end

  def stop!
    unless running?
      return { success: false, error: "Not running" }
    end

    begin
      Process.kill("TERM", pid)
      sleep 1

      if process_alive?
        Process.kill("KILL", pid)
      end
    rescue Errno::ESRCH
      # Process already gone
    end

    self.status = "stopped"
    self.stopped_at = Time.current
    save

    log_fact("stopped", "Epoch stopped")
    lifecycle_stopped!
    sync_to_kanban

    { success: true }
  end

  def pause!
    return { success: false, error: "Not running" } unless running?

    begin
      Process.kill("STOP", pid)
      self.status = "paused"
      save
      log_fact("paused", "Epoch paused")
      lifecycle_paused!
      sync_to_kanban
      { success: true }
    rescue Errno::ESRCH
      { success: false, error: "Process not found" }
    end
  end

  def resume!
    return { success: false, error: "Not paused" } unless status == "paused"

    begin
      Process.kill("CONT", pid)
      self.status = "running"
      save
      log_fact("resumed", "Epoch resumed")
      lifecycle_resumed!
      sync_to_kanban
      { success: true }
    rescue Errno::ESRCH
      { success: false, error: "Process not found" }
    end
  end

  def status_color
    case status
    when "running" then "green"
    when "completed" then "blue"
    when "paused" then "yellow"
    when "pending" then "gray"
    when "stopped" then "gray"
    when "max_iterations_reached" then "yellow"
    when "failed" then "red"
    else "gray"
    end
  end

  def main_log_path
    File.join(log_dir, "main.log")
  end

  def iteration_log_path(iter)
    File.join(log_dir, "iteration_#{iter}.log")
  end

  def main_log_content(lines: 100)
    return "" unless File.exist?(main_log_path)

    File.readlines(main_log_path).last(lines).join
  end

  def iteration_logs
    return [] unless Dir.exist?(log_dir)

    Dir.glob(File.join(log_dir, "iteration_*.log")).sort.map do |file|
      iter = File.basename(file, ".log").sub("iteration_", "").to_i
      {
        iteration: iter,
        path: file,
        size: File.size(file),
        content: File.read(file).truncate_bytes(5000)
      }
    end
  end

  def log_fact(predicate, object_value)
    fact = {
      timestamp: Time.current.iso8601,
      predicate: predicate,
      object_value: object_value
    }
    self.facts = (facts || []) + [fact]
    save
  end

  private

  def run_loop
    log("Epoch #{id} starting loop")
    log("Name: #{name}")
    log("Prompt: #{prompt}")
    log("Completion marker: #{completion_marker}")
    log("Max iterations: #{max_iterations || 'unlimited'}")
    lifecycle_running!

    loop do
      self.iteration += 1
      reload_state
      lifecycle_iteration!(iteration)

      if max_iterations && iteration > max_iterations
        log("Max iterations (#{max_iterations}) reached. Stopping.")
        self.status = "max_iterations_reached"
        self.completed_at = Time.current
        save
        log_fact("max_iterations_reached", "Stopped after #{iteration - 1} iterations")
        lifecycle_max_iterations!
        sync_to_kanban
        break
      end

      log("=== Iteration #{iteration} ===")

      begin
        Dir.chdir(working_dir || File.expand_path("~/Documents/RunSpace")) do
          output = run_claude_code
          log("Claude Code output length: #{output.length} chars")

          # Save iteration log
          File.write(iteration_log_path(iteration), output)
          lifecycle_iteration_completed!(iteration)

          if output.include?(completion_marker)
            log("Completion marker '#{completion_marker}' found! Task complete.")
            self.status = "completed"
            self.completed_at = Time.current
            save
            log_fact("completed", "Task completed at iteration #{iteration}")
            lifecycle_checkpoint! # Final checkpoint on completion
            lifecycle_completed!
            sync_to_kanban
            break
          else
            log("Completion marker not found. Continuing loop...")
          end
        end

        # Periodic checkpoint and Kanban sync
        if should_checkpoint?
          log("Running periodic checkpoint at iteration #{iteration}")
          checkpoint_result = lifecycle_checkpoint!
          if checkpoint_result[:success]
            log("Checkpoint complete: #{checkpoint_result[:repos].count { |r| r[:committed] }} commits")
          else
            log("Checkpoint had errors: #{checkpoint_result[:errors].join(', ')}")
          end
          sync_to_kanban # Sync to Kanban during checkpoint
        end
      rescue StandardError => e
        log("Error in iteration #{iteration}: #{e.message}")
        self.last_error = e.message
        self.status = "failed"
        save
        log_fact("error", e.message)
        lifecycle_checkpoint! # Checkpoint on failure to preserve state
        lifecycle_failed!(e.message)
        sync_to_kanban
        break
      end

      save
      sleep 2 # Brief pause between iterations
    end

    log("Epoch #{id} loop ended")
  end

  def run_claude_code
    prompt_with_marker = <<~PROMPT
      #{prompt}

      IMPORTANT: When the task is fully complete and all tests pass, output the marker: #{completion_marker}
      If the task is not complete, do NOT output this marker. Continue working on it.
    PROMPT

    `claude --print "#{prompt_with_marker.gsub('"', '\\"')}" 2>&1`
  end

  def reload_state
    return unless File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    # Only reload mutable state fields that might be changed externally
    self.status = data["status"] if data["status"]
  rescue JSON::ParserError
    # Ignore parse errors
  end

  def log(message)
    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    puts "[#{timestamp}] [#{id}] #{message}"
  end
end

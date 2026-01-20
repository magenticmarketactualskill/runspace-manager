#!/usr/bin/env ruby
# frozen_string_literal: true

# Ralph Wiggins - A persistent, autonomous loop runner for Claude Code
# Implements the "Ralph Wiggum" programming methodology
# Also manages Docker orchestration for MCP servers
# See doc/ralph_wigging.md for details

require "fileutils"
require "json"
require "optparse"
require "net/http"

class RalphWiggins
  PID_FILE = "tmp/pids/ralph_wiggins.pid"
  LOG_FILE = "log/ralph_wiggins.log"
  STATE_FILE = "tmp/ralph_wiggins_state.json"

  # Docker orchestration
  RUNSPACE_ROOT = File.expand_path("~/Documents/RunSpace")
  COMPOSE_FILE = File.join(RUNSPACE_ROOT, "docker-compose.yml")
  DOCKER_LOG_FILE = File.join(RUNSPACE_ROOT, ".runspace", "docker.log")
  DOCKER_STATUS_FILE = File.join(RUNSPACE_ROOT, ".runspace", "docker_status.json")

  DOCKER_SERVICES = {
    typestore: {
      name: "TypeStore",
      container: "runspace-typestore",
      port: 3001,
      health_url: "http://localhost:3001/up"
    },
    collaborativekanban: {
      name: "CollaborativeKanban",
      container: "runspace-collaborativekanban",
      port: 3002,
      health_url: "http://localhost:3002/up"
    },
    magenticresources: {
      name: "MagenticResources",
      container: "runspace-magenticresources",
      port: 3003,
      health_url: "http://localhost:3003/up"
    }
  }.freeze

  def initialize
    @options = {
      max_iterations: nil,
      prompt: nil,
      completion_marker: "RALPH_DONE",
      working_dir: Dir.pwd,
      daemon: false
    }
  end

  def run(args)
    command = args.shift

    case command
    when "start"
      parse_start_options(args)
      start
    when "stop"
      stop
    when "status"
      status
    # Docker orchestration commands
    when "docker:start"
      parse_docker_start_options(args)
      docker_start
    when "docker:stop"
      docker_stop
    when "docker:restart"
      docker_restart
    when "docker:status"
      docker_status
    when "docker:logs"
      docker_logs(args.first)
    when "docker:build"
      docker_build
    when "docker:epoch"
      docker_epoch
    else
      usage
    end
  end

  private

  def parse_start_options(args)
    OptionParser.new do |opts|
      opts.banner = "Usage: ralph_wiggins.rb start [options]"

      opts.on("-p", "--prompt PROMPT", "The prompt to run (required)") do |p|
        @options[:prompt] = p
      end

      opts.on("-f", "--prompt-file FILE", "Read prompt from file") do |f|
        @options[:prompt] = File.read(f)
      end

      opts.on("-m", "--max-iterations N", Integer, "Maximum iterations before stopping") do |n|
        @options[:max_iterations] = n
      end

      opts.on("-c", "--completion-marker MARKER", "Marker indicating completion (default: RALPH_DONE)") do |m|
        @options[:completion_marker] = m
      end

      opts.on("-w", "--working-dir DIR", "Working directory for Claude Code") do |d|
        @options[:working_dir] = d
      end

      opts.on("-d", "--daemon", "Run in background (daemon mode)") do
        @options[:daemon] = true
      end
    end.parse!(args)

    unless @options[:prompt]
      puts "Error: --prompt or --prompt-file is required"
      exit 1
    end
  end

  def parse_docker_start_options(args)
    OptionParser.new do |opts|
      opts.banner = "Usage: ralph_wiggins.rb docker:start [options]"

      opts.on("-p", "--prompt PROMPT", "The prompt to run Claude with") do |p|
        @options[:prompt] = p
      end

      opts.on("-f", "--prompt-file FILE", "Read prompt from file") do |f|
        @options[:prompt] = File.read(f)
      end

      opts.on("-m", "--max-iterations N", Integer, "Maximum Claude iterations before stopping") do |n|
        @options[:max_iterations] = n
      end

      opts.on("-c", "--completion-marker MARKER", "Marker indicating completion (default: RALPH_DONE)") do |m|
        @options[:completion_marker] = m
      end

      opts.on("-d", "--working-dir DIR", "Working directory for Claude Code") do |d|
        @options[:working_dir] = d
      end

      opts.on("--no-claude", "Start Docker only, don't run Claude loop") do
        @options[:no_claude] = true
      end
    end.parse!(args)

    # Default prompt for autonomous monitoring if none specified
    @options[:prompt] ||= default_docker_prompt unless @options[:no_claude]
  end

  def default_docker_prompt
    <<~PROMPT
      You are running in autonomous Ralph Wiggins mode with MCP servers.

      Available MCP servers:
      - TypeStore (port 3001): Type storage and retrieval
      - CollaborativeKanban (port 3002): Kanban board management
      - MagenticResources (port 3003): Resource management

      Check the current state of the RunSpace project and continue working on any
      pending tasks. Look for task files, checkpoint files, or kanban items that
      need attention.

      If there are no pending tasks, perform system health checks and report status.
    PROMPT
  end

  def start
    if running?
      puts "Ralph Wiggins is already running (PID: #{current_pid})"
      exit 1
    end

    ensure_directories

    if @options[:daemon]
      start_daemon
    else
      start_foreground
    end
  end

  def start_foreground
    pid = Process.pid
    File.write(PID_FILE, pid.to_s)

    save_state(
      pid: pid,
      started_at: Time.now.iso8601,
      prompt: @options[:prompt],
      max_iterations: @options[:max_iterations],
      completion_marker: @options[:completion_marker],
      iteration: 0,
      status: "running"
    )

    puts "Ralph Wiggins started in foreground (PID: #{pid})"
    puts "Max iterations: #{@options[:max_iterations] || 'unlimited'}"
    puts "Press Ctrl+C to stop"
    puts

    # Set up signal handlers for graceful shutdown
    trap("INT") do
      puts "\nReceived interrupt signal. Stopping..."
      update_state(status: "stopped", stopped_at: Time.now.iso8601)
      cleanup_files
      exit 0
    end

    trap("TERM") do
      puts "\nReceived terminate signal. Stopping..."
      update_state(status: "stopped", stopped_at: Time.now.iso8601)
      cleanup_files
      exit 0
    end

    run_loop
  end

  def start_daemon
    pid = fork do
      Process.setsid
      $stdin.reopen("/dev/null")
      $stdout.reopen(LOG_FILE, "a")
      $stderr.reopen($stdout)
      $stdout.sync = true

      run_loop
    end

    Process.detach(pid)
    File.write(PID_FILE, pid.to_s)

    save_state(
      pid: pid,
      started_at: Time.now.iso8601,
      prompt: @options[:prompt],
      max_iterations: @options[:max_iterations],
      completion_marker: @options[:completion_marker],
      iteration: 0,
      status: "running"
    )

    puts "Ralph Wiggins started in daemon mode (PID: #{pid})"
    puts "Log file: #{LOG_FILE}"
    puts "Max iterations: #{@options[:max_iterations] || 'unlimited'}"
  end

  def stop
    unless running?
      puts "Ralph Wiggins is not running"
      cleanup_files
      return
    end

    pid = current_pid
    puts "Stopping Ralph Wiggins (PID: #{pid})..."

    begin
      Process.kill("TERM", pid)
      sleep 1

      if process_exists?(pid)
        Process.kill("KILL", pid)
      end
    rescue Errno::ESRCH
      # Process already gone
    end

    update_state(status: "stopped", stopped_at: Time.now.iso8601)
    cleanup_files
    puts "Ralph Wiggins stopped"
  end

  def status
    if running?
      state = load_state
      puts "Ralph Wiggins is running"
      puts "  PID: #{current_pid}"
      puts "  Started: #{state['started_at']}"
      puts "  Iteration: #{state['iteration']}"
      puts "  Max iterations: #{state['max_iterations'] || 'unlimited'}"
      puts "  Completion marker: #{state['completion_marker']}"
      puts "  Status: #{state['status']}"
    else
      puts "Ralph Wiggins is not running"
      if File.exist?(STATE_FILE)
        state = load_state
        puts "  Last run: #{state['started_at']}"
        puts "  Stopped: #{state['stopped_at']}"
        puts "  Final iteration: #{state['iteration']}"
        puts "  Final status: #{state['status']}"
      end
    end
  end

  def run_loop
    iteration = 0
    log("Ralph Wiggins starting loop")
    log("Prompt: #{@options[:prompt]}")
    log("Completion marker: #{@options[:completion_marker]}")
    log("Max iterations: #{@options[:max_iterations] || 'unlimited'}")

    loop do
      iteration += 1
      update_state(iteration: iteration)

      if @options[:max_iterations] && iteration > @options[:max_iterations]
        log("Max iterations (#{@options[:max_iterations]}) reached. Stopping.")
        update_state(status: "max_iterations_reached")
        break
      end

      log("=== Iteration #{iteration} ===")

      Dir.chdir(@options[:working_dir]) do
        output = run_claude_code
        log("Claude Code output length: #{output.length} chars")

        if output.include?(@options[:completion_marker])
          log("Completion marker '#{@options[:completion_marker]}' found! Task complete.")
          update_state(status: "completed")
          break
        else
          log("Completion marker not found. Continuing loop...")
        end
      end

      sleep 2 # Brief pause between iterations
    end

    log("Ralph Wiggins loop ended")
  end

  def run_claude_code
    prompt_with_marker = <<~PROMPT
      #{@options[:prompt]}

      IMPORTANT: When the task is fully complete and all tests pass, output the marker: #{@options[:completion_marker]}
      If the task is not complete, do NOT output this marker. Continue working on it.
    PROMPT

    # Run claude code with the prompt
    output = `claude --print "#{prompt_with_marker.gsub('"', '\\"')}" 2>&1`
    log_file = "tmp/ralph_iteration_#{load_state['iteration']}.log"
    File.write(log_file, output)
    output
  end

  def running?
    return false unless File.exist?(PID_FILE)
    process_exists?(current_pid)
  end

  def current_pid
    File.read(PID_FILE).to_i
  end

  def process_exists?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true # Process exists but we don't have permission
  end

  def ensure_directories
    FileUtils.mkdir_p("tmp/pids")
    FileUtils.mkdir_p("log")
  end

  def cleanup_files
    FileUtils.rm_f(PID_FILE)
  end

  def save_state(state)
    ensure_directories
    File.write(STATE_FILE, JSON.pretty_generate(state))
  end

  def load_state
    return {} unless File.exist?(STATE_FILE)
    JSON.parse(File.read(STATE_FILE))
  end

  def update_state(updates)
    state = load_state.merge(updates.transform_keys(&:to_s))
    save_state(state)
  end

  def log(message)
    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    puts "[#{timestamp}] #{message}"
  end

  # Docker orchestration methods

  def docker_log(message)
    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    log_dir = File.dirname(DOCKER_LOG_FILE)
    FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)
    log_line = "[#{timestamp}] #{message}"
    puts log_line
    File.open(DOCKER_LOG_FILE, "a") { |f| f.puts log_line }
  end

  def docker_available?
    system("docker --version > /dev/null 2>&1")
  end

  def docker_running?
    system("docker info > /dev/null 2>&1")
  end

  def docker_check_prerequisites
    unless docker_available?
      docker_log("ERROR: Docker is not installed")
      exit 1
    end

    unless docker_running?
      docker_log("ERROR: Docker Desktop is not running. Please start Docker Desktop first.")
      exit 1
    end

    unless File.exist?(COMPOSE_FILE)
      docker_log("ERROR: docker-compose.yml not found at #{COMPOSE_FILE}")
      exit 1
    end
  end

  def docker_service_health(config)
    uri = URI(config[:health_url])
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = 5
    response = http.get(uri.path)
    response.code == "200"
  rescue StandardError
    false
  end

  def docker_service_status(config)
    container_status = `docker inspect --format='{{.State.Status}}' #{config[:container]} 2>/dev/null`.strip
    running = container_status == "running"
    healthy = running && docker_service_health(config)

    {
      name: config[:name],
      container: config[:container],
      port: config[:port],
      running: running,
      healthy: healthy,
      status: container_status.empty? ? "not created" : container_status
    }
  end

  def docker_all_services_status
    DOCKER_SERVICES.transform_values { |config| docker_service_status(config) }
  end

  def docker_save_status(status)
    status_dir = File.dirname(DOCKER_STATUS_FILE)
    FileUtils.mkdir_p(status_dir) unless Dir.exist?(status_dir)
    File.write(DOCKER_STATUS_FILE, JSON.pretty_generate(status.merge(updated_at: Time.now.iso8601)))
  end

  def docker_wait_for_healthy(timeout: 180)
    docker_log("Waiting for services to be healthy (timeout: #{timeout}s)...")
    start_time = Time.now

    loop do
      statuses = docker_all_services_status
      all_healthy = statuses.values.all? { |s| s[:healthy] }

      healthy_count = statuses.values.count { |s| s[:healthy] }
      running_count = statuses.values.count { |s| s[:running] }

      docker_log("  Running: #{running_count}/#{DOCKER_SERVICES.size}, Healthy: #{healthy_count}/#{DOCKER_SERVICES.size}")

      if all_healthy
        docker_log("All services are healthy!")
        docker_save_status(statuses)
        return true
      end

      elapsed = Time.now - start_time
      if elapsed > timeout
        docker_log("Timeout! Some services failed to become healthy.")
        docker_save_status(statuses)
        return false
      end

      sleep 10
    end
  end

  def docker_start
    docker_check_prerequisites

    docker_log("=" * 60)
    docker_log("RalphWiggins: Starting all MCP servers")
    docker_log("=" * 60)

    Dir.chdir(RUNSPACE_ROOT) do
      # Build images
      docker_log("Building Docker images...")
      build_output = `docker-compose build 2>&1`
      unless $?.success?
        docker_log("ERROR: Docker build failed")
        docker_log(build_output)
        exit 1
      end
      docker_log("Docker images built successfully")

      # Start containers in detached mode
      docker_log("Starting containers in detached mode...")
      start_output = `docker-compose up -d 2>&1`
      unless $?.success?
        docker_log("ERROR: Docker start failed")
        docker_log(start_output)
        exit 1
      end
      docker_log("Containers started")
    end

    # Wait for all services to be healthy
    unless docker_wait_for_healthy(timeout: 180)
      docker_log("ERROR: Services failed to become healthy")
      exit 1
    end

    docker_log("=" * 60)
    docker_log("All MCP servers running and healthy")
    docker_log("=" * 60)

    # Run Claude loop if not disabled
    if @options[:no_claude]
      docker_log("Claude loop disabled (--no-claude). Docker services running in background.")
      docker_print_status
    else
      docker_log("Starting Claude autonomous loop...")
      docker_log("Prompt: #{@options[:prompt][0..100]}...")
      docker_log("Max iterations: #{@options[:max_iterations] || 'unlimited'}")
      docker_log("Completion marker: #{@options[:completion_marker]}")
      docker_log("=" * 60)

      run_docker_claude_loop
    end
  end

  def run_docker_claude_loop
    iteration = 0

    # Set up signal handler to clean up Docker on exit
    trap("INT") do
      docker_log("\nReceived interrupt signal. Stopping...")
      docker_stop
      exit 0
    end

    trap("TERM") do
      docker_log("\nReceived terminate signal. Stopping...")
      docker_stop
      exit 0
    end

    loop do
      iteration += 1

      if @options[:max_iterations] && iteration > @options[:max_iterations]
        docker_log("Max iterations (#{@options[:max_iterations]}) reached. Stopping.")
        break
      end

      docker_log("=== Claude Iteration #{iteration} ===")

      # Check Docker health before each iteration
      statuses = docker_all_services_status
      unhealthy = statuses.select { |_k, v| !v[:healthy] }

      if unhealthy.any?
        docker_log("Unhealthy services detected: #{unhealthy.keys.join(', ')}")
        docker_log("Attempting to restart unhealthy services...")

        unhealthy.each do |key, _status|
          config = DOCKER_SERVICES[key]
          docker_log("Restarting #{config[:name]}...")
          `docker restart #{config[:container]} 2>&1`
        end

        # Wait for recovery
        unless docker_wait_for_healthy(timeout: 60)
          docker_log("WARNING: Some services still unhealthy, continuing anyway...")
        end
      end

      # Run Claude
      Dir.chdir(@options[:working_dir]) do
        output = run_claude_code_for_docker
        docker_log("Claude output length: #{output.length} chars")

        if output.include?(@options[:completion_marker])
          docker_log("Completion marker '#{@options[:completion_marker]}' found! Task complete.")
          break
        else
          docker_log("Completion marker not found. Continuing loop...")
        end
      end

      sleep 5 # Brief pause between iterations
    end

    docker_log("Claude loop ended")
    docker_log("Docker services still running. Use 'docker:stop' to stop them.")
  end

  def run_claude_code_for_docker
    prompt_with_context = <<~PROMPT
      #{@options[:prompt]}

      IMPORTANT: When the task is fully complete, output the marker: #{@options[:completion_marker]}
      If the task is not complete, do NOT output this marker. Continue working on it.
    PROMPT

    # Run claude code with the prompt
    output = `claude --print "#{prompt_with_context.gsub('"', '\\"')}" 2>&1`
    log_file = File.join("tmp", "ralph_docker_iteration_#{Time.now.strftime('%Y%m%d_%H%M%S')}.log")
    FileUtils.mkdir_p("tmp")
    File.write(log_file, output)
    output
  end

  def docker_stop
    docker_check_prerequisites

    docker_log("Stopping all MCP servers...")

    Dir.chdir(RUNSPACE_ROOT) do
      output = `docker-compose down 2>&1`
      if $?.success?
        docker_log("All services stopped")
      else
        docker_log("Error stopping services: #{output}")
      end
    end
  end

  def docker_restart
    docker_stop
    sleep 3
    docker_start
  end

  def docker_status
    unless docker_available? && docker_running?
      docker_log("Docker is not available")
      exit 1
    end

    docker_print_status
  end

  def docker_print_status
    statuses = docker_all_services_status
    docker_save_status(statuses)

    puts "\n#{'=' * 60}"
    puts "RunSpace MCP Servers Status"
    puts "#{'=' * 60}\n"

    statuses.each do |_key, status|
      health_indicator = status[:healthy] ? "✅" : (status[:running] ? "🟡" : "❌")
      puts "#{health_indicator} #{status[:name]}"
      puts "   Container: #{status[:container]}"
      puts "   Port:      #{status[:port]}"
      puts "   Status:    #{status[:status]}"
      puts "   Healthy:   #{status[:healthy]}"
      puts
    end

    all_healthy = statuses.values.all? { |s| s[:healthy] }
    puts "#{'=' * 60}"
    puts all_healthy ? "All services healthy ✅" : "Some services need attention ⚠️"
    puts "#{'=' * 60}"
  end

  def docker_logs(service = nil)
    if service
      config = DOCKER_SERVICES[service.to_sym]
      if config
        puts `docker logs --tail 100 #{config[:container]} 2>&1`
      else
        docker_log("Unknown service: #{service}")
      end
    else
      DOCKER_SERVICES.each do |_key, config|
        puts "\n#{'=' * 40}"
        puts "Logs for #{config[:name]}"
        puts "#{'=' * 40}"
        puts `docker logs --tail 20 #{config[:container]} 2>&1`
      end
    end
  end

  def docker_build
    docker_check_prerequisites

    docker_log("Building all Docker images...")

    Dir.chdir(RUNSPACE_ROOT) do
      output = `docker-compose build 2>&1`
      puts output

      if $?.success?
        docker_log("Build complete!")
      else
        docker_log("Build failed!")
        exit 1
      end
    end
  end

  def docker_epoch
    # Start as an autonomous epoch that monitors and maintains services
    docker_log("Starting RalphWiggins Docker autonomous epoch mode...")

    # First, ensure everything is running
    docker_start

    # Then enter monitoring loop
    docker_log("Entering monitoring mode...")
    iteration = 0

    loop do
      iteration += 1
      docker_log("Monitoring iteration #{iteration}")

      statuses = docker_all_services_status
      unhealthy = statuses.select { |_k, v| !v[:healthy] }

      if unhealthy.any?
        docker_log("Unhealthy services detected: #{unhealthy.keys.join(', ')}")

        # Try to restart unhealthy containers
        unhealthy.each do |key, _status|
          config = DOCKER_SERVICES[key]
          docker_log("Restarting #{config[:name]}...")
          `docker restart #{config[:container]} 2>&1`
        end

        # Wait for recovery
        sleep 30
        docker_wait_for_healthy(timeout: 60)
      else
        docker_log("All services healthy")
      end

      # Check every 5 minutes
      sleep 300
    end
  end

  def usage
    puts <<~USAGE
      Ralph Wiggins - Persistent autonomous loop runner for Claude Code
                      Also manages Docker orchestration for MCP servers

      Usage:
        ralph_wiggins.rb start [options]  Start the loop
        ralph_wiggins.rb stop             Stop the running loop
        ralph_wiggins.rb status           Show status

      Docker Commands:
        ralph_wiggins.rb docker:start [options]  Start MCP servers + Claude loop
        ralph_wiggins.rb docker:stop             Stop all MCP servers
        ralph_wiggins.rb docker:restart          Restart all MCP servers
        ralph_wiggins.rb docker:status           Show status of all services
        ralph_wiggins.rb docker:logs             Show recent logs (docker:logs <service>)
        ralph_wiggins.rb docker:build            Build Docker images only
        ralph_wiggins.rb docker:epoch            Start autonomous monitoring mode

      Start options (for 'start' command):
        -p, --prompt PROMPT           The prompt to run (required)
        -f, --prompt-file FILE        Read prompt from file
        -m, --max-iterations N        Maximum iterations (safety limit)
        -c, --completion-marker TEXT  Marker indicating completion (default: RALPH_DONE)
        -w, --working-dir DIR         Working directory
        -d, --daemon                  Run in background (daemon mode)

      Docker:start options:
        -p, --prompt PROMPT           Prompt for Claude (default: autonomous monitoring)
        -f, --prompt-file FILE        Read prompt from file
        -m, --max-iterations N        Maximum Claude iterations
        -c, --completion-marker TEXT  Completion marker (default: RALPH_DONE)
        -d, --working-dir DIR         Working directory for Claude
        --no-claude                   Start Docker only, skip Claude loop

      Docker Services:
        - TypeStore (port 3001)
        - CollaborativeKanban (port 3002)
        - MagenticResources (port 3003)

      Examples:
        # Autonomous loop - runs continuously in foreground (Ctrl+C to stop)
        ralph_wiggins.rb start -p "Fix all failing tests" -m 10
        ralph_wiggins.rb start -f task.md --max-iterations 50

        # Run as background daemon
        ralph_wiggins.rb start -p "Fix all failing tests" -d

        # Docker + Claude continuous loop (default prompt)
        ralph_wiggins.rb docker:start

        # Docker + Claude with custom prompt
        ralph_wiggins.rb docker:start -p "Build the new feature" -m 20
        ralph_wiggins.rb docker:start -f task.md

        # Docker only (no Claude loop)
        ralph_wiggins.rb docker:start --no-claude

        # Docker management
        ralph_wiggins.rb docker:status
        ralph_wiggins.rb docker:logs typestore
    USAGE
  end
end

RalphWiggins.new.run(ARGV)

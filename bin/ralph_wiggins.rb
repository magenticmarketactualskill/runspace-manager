#!/usr/bin/env ruby
# frozen_string_literal: true

# Ralph Wiggins - A persistent, autonomous loop runner for Claude Code
# Implements the "Ralph Wiggum" programming methodology
# See doc/ralph_wigging.md for details

require "fileutils"
require "json"
require "optparse"

class RalphWiggins
  PID_FILE = "tmp/pids/ralph_wiggins.pid"
  LOG_FILE = "log/ralph_wiggins.log"
  STATE_FILE = "tmp/ralph_wiggins_state.json"

  def initialize
    @options = {
      max_iterations: nil,
      prompt: nil,
      completion_marker: "RALPH_DONE",
      working_dir: Dir.pwd
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

      opts.on("-d", "--working-dir DIR", "Working directory for Claude Code") do |d|
        @options[:working_dir] = d
      end
    end.parse!(args)

    unless @options[:prompt]
      puts "Error: --prompt or --prompt-file is required"
      exit 1
    end
  end

  def start
    if running?
      puts "Ralph Wiggins is already running (PID: #{current_pid})"
      exit 1
    end

    ensure_directories

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

    puts "Ralph Wiggins started (PID: #{pid})"
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

  def usage
    puts <<~USAGE
      Ralph Wiggins - Persistent autonomous loop runner for Claude Code

      Usage:
        ralph_wiggins.rb start [options]  Start the loop
        ralph_wiggins.rb stop             Stop the running loop
        ralph_wiggins.rb status           Show status

      Start options:
        -p, --prompt PROMPT           The prompt to run (required)
        -f, --prompt-file FILE        Read prompt from file
        -m, --max-iterations N        Maximum iterations (safety limit)
        -c, --completion-marker TEXT  Marker indicating completion (default: RALPH_DONE)
        -d, --working-dir DIR         Working directory

      Example:
        ralph_wiggins.rb start -p "Fix all failing tests" -m 10
        ralph_wiggins.rb start -f task.md --max-iterations 50
        ralph_wiggins.rb status
        ralph_wiggins.rb stop
    USAGE
  end
end

RalphWiggins.new.run(ARGV)

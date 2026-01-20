# frozen_string_literal: true

require "task_frame"

# RalphWiggins::LifeCycle - Tracks lifecycle events and updates code_status.ini
# Provides hooks for Epoch lifecycle transitions and checkpoint operations
# Uses TaskFrame for multi-stage task lifecycle management
module RalphWiggins
  module LifeCycle
    RUNSPACE_DIR = File.expand_path("~/Documents/RunSpace/.runspace")
    RUNSPACE_ROOT = File.expand_path("~/Documents/RunSpace")
    STATUS_FILE = File.join(RUNSPACE_DIR, "code_status.ini")
    CHECKPOINT_FILE = File.join(RUNSPACE_DIR, "checkpoint.ini")
    CHECKPOINT_LOG = File.join(RUNSPACE_DIR, "checkpoint.log")

    # Default checkpoint interval in iterations (used if not configured)
    DEFAULT_CHECKPOINT_FREQUENCY = 5

    # Maximum parallel git operations
    MAX_PARALLEL_REPOS = 4

    EVENTS = %w[
      initialized
      started
      running
      paused
      resumed
      iteration_started
      iteration_completed
      completed
      stopped
      failed
      max_iterations_reached
    ].freeze

    class << self
      def record(event, epoch: nil, details: {})
        raise ArgumentError, "Unknown event: #{event}" unless EVENTS.include?(event.to_s)

        ensure_directory
        update_status_file(event, epoch: epoch, details: details)
        log_event(event, epoch: epoch, details: details)
      end

      def current_status
        return {} unless File.exist?(STATUS_FILE)

        parse_ini_file(STATUS_FILE)
      end

      def active_epochs_status
        status = current_status
        (status["ACTIVE_EPOCHS"] || {}).map do |id, data|
          parse_epoch_data(id, data)
        end
      end

      # Checkpoint: commit all changes, push to repos, fetch GitHub recents
      # Uses TaskFrame for multi-stage lifecycle management with parallel git operations
      def checkpoint(epoch: nil, message: nil)
        ensure_directory
        timestamp = Time.now

        # Initialize TaskFrame for checkpoint lifecycle
        task = TaskFrame::Task.new(
          name: "checkpoint_#{timestamp.strftime('%Y%m%d_%H%M%S')}",
          metadata: { epoch_id: epoch&.id, started_at: timestamp.iso8601 }
        )

        results = {
          timestamp: timestamp.iso8601,
          epoch_id: epoch&.id,
          repos: [],
          github_recents: nil,
          github_access: nil,
          success: true,
          errors: [],
          task_frame: { stages: [] }
        }

        log_checkpoint("Starting checkpoint#{epoch ? " for epoch #{epoch.id}" : ""}")

        # Stage 1: Verify GitHub Access
        task.stage(:verify_github_access) do
          log_checkpoint("[Stage 1] Verifying GitHub access")
          github_access = Hive.confirm_github_access
          results[:github_access] = github_access
          results[:task_frame][:stages] << { name: :verify_github_access, success: github_access[:success] }

          if github_access[:success]
            log_checkpoint("GitHub access confirmed for user: #{github_access[:username]}")
          else
            log_checkpoint("GitHub access not available: #{github_access[:error]}")
          end

          github_access
        end

        github_available = results[:github_access][:success]

        # Stage 2: Discover Repositories
        task.stage(:discover_repos) do
          log_checkpoint("[Stage 2] Discovering git repositories")
          repos = find_git_repos
          log_checkpoint("Found #{repos.size} git repositories")
          results[:task_frame][:stages] << { name: :discover_repos, repos_found: repos.size }
          repos
        end

        repos = task.result(:discover_repos)

        # Stage 3: Parallel Git Operations (commit, push, fetch)
        task.stage(:git_operations) do
          log_checkpoint("[Stage 3] Running parallel git operations on #{repos.size} repos")

          # Process repos in parallel using thread pool
          repo_results = parallel_process_repos(
            repos,
            message: message,
            epoch: epoch,
            push_enabled: github_available
          )

          repo_results.each do |repo_result|
            results[:repos] << repo_result
            results[:errors] << repo_result[:error] if repo_result[:error]
          end

          results[:task_frame][:stages] << {
            name: :git_operations,
            repos_processed: repo_results.size,
            committed: repo_results.count { |r| r[:committed] },
            pushed: repo_results.count { |r| r[:pushed] }
          }

          repo_results
        end

        # Stage 4: Fetch GitHub Recents (parallel with stage 3 completion)
        task.stage(:fetch_github_recents) do
          log_checkpoint("[Stage 4] Fetching GitHub recents")

          if github_available
            github_result = fetch_github_recents
            results[:github_recents] = github_result
            results[:errors] << github_result[:error] if github_result[:error]
            results[:task_frame][:stages] << { name: :fetch_github_recents, success: github_result[:error].nil? }
          else
            results[:github_recents] = { skipped: true, reason: results[:github_access][:error] }
            results[:task_frame][:stages] << { name: :fetch_github_recents, skipped: true }
          end

          results[:github_recents]
        end

        # Stage 5: Finalize
        task.stage(:finalize) do
          log_checkpoint("[Stage 5] Finalizing checkpoint")
          results[:success] = results[:errors].compact.empty?
          results[:task_frame][:completed_at] = Time.now.iso8601
          results[:task_frame][:stages] << { name: :finalize, success: results[:success] }

          # Update checkpoint status file
          update_checkpoint_status(results)

          log_checkpoint("Checkpoint complete: #{results[:repos].count { |r| r[:committed] }} commits, #{results[:repos].count { |r| r[:pushed] }} pushes")
        end

        # Execute all stages
        task.execute!

        results
      end

      # Process multiple repos in parallel using threads
      def parallel_process_repos(repos, message:, epoch:, push_enabled:)
        return [] if repos.empty?

        mutex = Mutex.new
        results = []

        # Split repos into batches for parallel processing
        repos.each_slice([repos.size, MAX_PARALLEL_REPOS].min).flat_map do |batch|
          threads = batch.map do |repo_path|
            Thread.new do
              result = process_repo(repo_path, message: message, epoch: epoch, push_enabled: push_enabled)
              mutex.synchronize { results << result }
            end
          end

          threads.each(&:join)
        end

        results
      end

      def last_checkpoint
        return nil unless File.exist?(CHECKPOINT_FILE)

        parse_ini_file(CHECKPOINT_FILE)
      end

      def checkpoint_frequency
        config = last_checkpoint
        freq = config&.dig("CHECKPOINT", "frequency")&.to_i
        freq && freq > 0 ? freq : DEFAULT_CHECKPOINT_FREQUENCY
      end

      def checkpoint_frequency=(value)
        ensure_directory
        config = last_checkpoint || {}
        config["CHECKPOINT"] ||= {}
        config["CHECKPOINT"]["frequency"] = value.to_s
        write_ini_file(CHECKPOINT_FILE, config)
        value
      end

      def should_checkpoint?(iteration)
        return false if iteration <= 0

        freq = checkpoint_frequency
        (iteration % freq).zero?
      end

      private

      def find_git_repos
        repos = []

        # Main RunSpace directory
        repos << RUNSPACE_ROOT if git_repo?(RUNSPACE_ROOT)

        # RunSpaceManager
        manager_path = File.join(RUNSPACE_ROOT, "RunSpaceManager")
        repos << manager_path if git_repo?(manager_path)

        # MCP Servers
        mcp_dir = File.join(RUNSPACE_ROOT, "mcp_servers")
        if Dir.exist?(mcp_dir)
          Dir.children(mcp_dir).each do |child|
            path = File.join(mcp_dir, child)
            repos << path if git_repo?(path)
          end
        end

        # Gems
        gem_dir = File.join(RUNSPACE_ROOT, "gem")
        if Dir.exist?(gem_dir)
          Dir.children(gem_dir).each do |child|
            path = File.join(gem_dir, child)
            repos << path if git_repo?(path)
          end
        end

        repos.uniq
      end

      def git_repo?(path)
        File.directory?(path) && File.directory?(File.join(path, ".git"))
      end

      def process_repo(repo_path, message: nil, epoch: nil, push_enabled: true)
        repo_name = File.basename(repo_path)
        result = {
          path: repo_path,
          name: repo_name,
          committed: false,
          pushed: false,
          push_skipped: false,
          fetched: false,
          error: nil
        }

        Dir.chdir(repo_path) do
          # Check for changes
          status_output = `git status --porcelain 2>&1`
          has_changes = !status_output.strip.empty?

          if has_changes
            # Stage all changes
            `git add -A 2>&1`

            # Generate commit message
            commit_msg = message || generate_commit_message(epoch)

            # Commit
            commit_output = `git commit -m "#{commit_msg}" 2>&1`
            result[:committed] = $?.success?
            result[:commit_message] = commit_msg

            unless result[:committed]
              result[:error] = "Commit failed: #{commit_output}"
              log_checkpoint("#{repo_name}: Commit failed - #{commit_output}")
            else
              log_checkpoint("#{repo_name}: Committed changes")
            end
          end

          # Push if we have a remote and GitHub access is confirmed
          remote_output = `git remote -v 2>&1`
          has_remote = remote_output.include?("origin")

          if has_remote
            if push_enabled
              push_output = `git push 2>&1`
              result[:pushed] = $?.success?

              if result[:pushed]
                log_checkpoint("#{repo_name}: Pushed to remote")
              else
                # Don't treat push failures as errors if nothing to push
                unless push_output.include?("Everything up-to-date")
                  result[:error] = "Push failed: #{push_output}"
                  log_checkpoint("#{repo_name}: Push failed - #{push_output}")
                end
              end

              # Fetch latest
              fetch_output = `git fetch --all 2>&1`
              result[:fetched] = $?.success?
            else
              result[:push_skipped] = true
              log_checkpoint("#{repo_name}: Push skipped (GitHub access not confirmed)")
            end
          end
        end

        result
      rescue StandardError => e
        result[:error] = e.message
        log_checkpoint("#{repo_name}: Error - #{e.message}")
        result
      end

      def generate_commit_message(epoch)
        timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        if epoch
          "[RalphWiggins] Checkpoint - Epoch: #{epoch.name}, Iteration: #{epoch.iteration} (#{timestamp})"
        else
          "[RalphWiggins] Checkpoint (#{timestamp})"
        end
      end

      def fetch_github_recents
        result = {
          notifications: [],
          issues: [],
          pull_requests: [],
          fetched_at: Time.now.iso8601,
          error: nil
        }

        begin
          # GitHub access already confirmed via Hive.confirm_github_access
          # Fetch notifications
          notifications_json = `gh api notifications --jq '[.[] | {id: .id, reason: .reason, subject: .subject.title, repo: .repository.full_name, updated_at: .updated_at}]' 2>&1`
          if $?.success?
            result[:notifications] = JSON.parse(notifications_json) rescue []
            log_checkpoint("Fetched #{result[:notifications].size} GitHub notifications")
          end

          # Fetch recent issues assigned to user
          issues_json = `gh api 'search/issues?q=assignee:@me+is:open+is:issue&per_page=10' --jq '[.items[] | {number: .number, title: .title, repo: .repository_url, state: .state, updated_at: .updated_at}]' 2>&1`
          if $?.success?
            result[:issues] = JSON.parse(issues_json) rescue []
            log_checkpoint("Fetched #{result[:issues].size} assigned issues")
          end

          # Fetch recent PRs for review
          prs_json = `gh api 'search/issues?q=review-requested:@me+is:open+is:pr&per_page=10' --jq '[.items[] | {number: .number, title: .title, repo: .repository_url, state: .state, updated_at: .updated_at}]' 2>&1`
          if $?.success?
            result[:pull_requests] = JSON.parse(prs_json) rescue []
            log_checkpoint("Fetched #{result[:pull_requests].size} PRs for review")
          end

        rescue StandardError => e
          result[:error] = e.message
        end

        result
      end

      def update_checkpoint_status(results)
        github_recents = results[:github_recents] || {}
        github_access = results[:github_access] || {}
        task_frame = results[:task_frame] || {}

        # Preserve existing frequency setting
        current_frequency = checkpoint_frequency

        status = {
          "CHECKPOINT" => {
            "frequency" => current_frequency.to_s,
            "last_checkpoint_at" => results[:timestamp],
            "completed_at" => task_frame[:completed_at] || "",
            "epoch_id" => results[:epoch_id] || "",
            "success" => results[:success].to_s,
            "repos_processed" => results[:repos].size.to_s,
            "repos_committed" => results[:repos].count { |r| r[:committed] }.to_s,
            "repos_pushed" => results[:repos].count { |r| r[:pushed] }.to_s,
            "repos_push_skipped" => results[:repos].count { |r| r[:push_skipped] }.to_s,
            "errors_count" => results[:errors].compact.size.to_s,
            "parallel_processing" => "true"
          },
          "TASK_FRAME" => {
            "stages_count" => (task_frame[:stages]&.size || 0).to_s,
            "stages_completed" => task_frame[:stages]&.map { |s| s[:name] }&.join(",") || ""
          },
          "GITHUB_ACCESS" => {
            "verified" => github_access[:success].to_s,
            "username" => github_access[:username] || "",
            "error" => github_access[:error] || ""
          },
          "REPOS" => {},
          "GITHUB" => {
            "notifications_count" => (github_recents[:notifications]&.size || 0).to_s,
            "issues_count" => (github_recents[:issues]&.size || 0).to_s,
            "pull_requests_count" => (github_recents[:pull_requests]&.size || 0).to_s,
            "fetched_at" => github_recents[:fetched_at] || "",
            "skipped" => (github_recents[:skipped] || false).to_s
          }
        }

        results[:repos].each do |repo|
          status["REPOS"][repo[:name]] = "#{repo[:committed]}|#{repo[:pushed]}|#{repo[:push_skipped]}|#{repo[:fetched]}|#{repo[:error] || 'ok'}"
        end

        write_ini_file(CHECKPOINT_FILE, status)
      end

      def log_checkpoint(message)
        timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        File.open(CHECKPOINT_LOG, "a") do |f|
          f.puts "[#{timestamp}] #{message}"
        end
      end

      def ensure_directory
        FileUtils.mkdir_p(RUNSPACE_DIR)
      end

      def update_status_file(event, epoch: nil, details: {})
        status = current_status
        timestamp = Time.now.iso8601

        # Update global status section
        status["STATUS"] ||= {}
        status["STATUS"]["last_event"] = event.to_s
        status["STATUS"]["last_event_at"] = timestamp
        status["STATUS"]["running_count"] = Epoch.running.count.to_s rescue "0"
        status["STATUS"]["total_epochs"] = Epoch.all.count.to_s rescue "0"

        # Update epoch-specific section if epoch provided
        if epoch
          status["ACTIVE_EPOCHS"] ||= {}
          epoch_key = epoch.id || "unknown"

          case event.to_s
          when "started", "running", "paused", "resumed", "iteration_started", "iteration_completed"
            status["ACTIVE_EPOCHS"][epoch_key] = build_epoch_status(epoch, event, timestamp)
          when "completed", "stopped", "failed", "max_iterations_reached"
            # Move to completed section
            status["COMPLETED_EPOCHS"] ||= {}
            status["COMPLETED_EPOCHS"][epoch_key] = build_epoch_status(epoch, event, timestamp)
            status["ACTIVE_EPOCHS"].delete(epoch_key)
          end
        end

        # Update history section (keep last 10 events)
        status["HISTORY"] ||= {}
        history_key = "event_#{timestamp.gsub(/[^0-9]/, '')}"
        status["HISTORY"][history_key] = "#{event}|#{epoch&.id || 'system'}|#{details.to_json}"

        # Trim history to last 10 entries
        if status["HISTORY"].size > 10
          keys_to_remove = status["HISTORY"].keys.sort.first(status["HISTORY"].size - 10)
          keys_to_remove.each { |k| status["HISTORY"].delete(k) }
        end

        write_ini_file(STATUS_FILE, status)
      end

      def build_epoch_status(epoch, event, timestamp)
        [
          epoch.name,
          epoch.status,
          event.to_s,
          timestamp,
          epoch.iteration.to_s,
          epoch.pid.to_s
        ].join("|")
      end

      def parse_epoch_data(id, data)
        parts = data.split("|")
        {
          id: id,
          name: parts[0],
          status: parts[1],
          last_event: parts[2],
          last_event_at: parts[3],
          iteration: parts[4].to_i,
          pid: parts[5].to_i
        }
      end

      def log_event(event, epoch: nil, details: {})
        log_file = File.join(RUNSPACE_DIR, "lifecycle.log")
        timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        epoch_info = epoch ? "[#{epoch.id}] " : ""
        detail_str = details.any? ? " #{details.inspect}" : ""

        File.open(log_file, "a") do |f|
          f.puts "[#{timestamp}] #{epoch_info}#{event}#{detail_str}"
        end
      end

      def parse_ini_file(path)
        result = {}
        current_section = nil

        File.readlines(path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          if line.match?(/^\[.+\]$/)
            current_section = line[1..-2]
            result[current_section] ||= {}
          elsif current_section && line.include?("=")
            key, value = line.split("=", 2).map(&:strip)
            result[current_section][key] = value
          end
        end

        result
      end

      def write_ini_file(path, data)
        content = []

        data.each do |section, values|
          content << "[#{section}]"
          values.each do |key, value|
            content << "#{key} = #{value}"
          end
          content << ""
        end

        File.write(path, content.join("\n"))
      end
    end

    # Instance methods to include in Epoch
    module EpochIntegration
      def lifecycle_start!
        LifeCycle.record(:started, epoch: self)
      end

      def lifecycle_running!
        LifeCycle.record(:running, epoch: self)
      end

      def lifecycle_paused!
        LifeCycle.record(:paused, epoch: self)
      end

      def lifecycle_resumed!
        LifeCycle.record(:resumed, epoch: self)
      end

      def lifecycle_iteration!(iteration_num)
        LifeCycle.record(:iteration_started, epoch: self, details: { iteration: iteration_num })
      end

      def lifecycle_iteration_completed!(iteration_num)
        LifeCycle.record(:iteration_completed, epoch: self, details: { iteration: iteration_num })
      end

      def lifecycle_completed!
        LifeCycle.record(:completed, epoch: self)
      end

      def lifecycle_stopped!
        LifeCycle.record(:stopped, epoch: self)
      end

      def lifecycle_failed!(error)
        LifeCycle.record(:failed, epoch: self, details: { error: error })
      end

      def lifecycle_max_iterations!
        LifeCycle.record(:max_iterations_reached, epoch: self)
      end

      def lifecycle_checkpoint!
        LifeCycle.checkpoint(epoch: self)
      end

      def should_checkpoint?
        LifeCycle.should_checkpoint?(iteration)
      end

      def checkpoint_frequency
        LifeCycle.checkpoint_frequency
      end

      def checkpoint_frequency=(value)
        LifeCycle.checkpoint_frequency = value
      end
    end
  end
end

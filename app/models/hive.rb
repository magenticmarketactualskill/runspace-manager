# frozen_string_literal: true

# Hive - Central coordination and registry module for RunSpaceManager
# Maintains the .hive folder for shared state, worker registry, and coordination
class Hive
  HIVE_DIR = Rails.root.join(".hive")
  REGISTRY_FILE = File.join(HIVE_DIR, "registry.json")
  STATE_FILE = File.join(HIVE_DIR, "state.ini")
  WORKERS_DIR = File.join(HIVE_DIR, "workers")
  MESSAGES_DIR = File.join(HIVE_DIR, "messages")

  class << self
    def setup!
      ensure_directories
      initialize_state unless File.exist?(STATE_FILE)
      initialize_registry unless File.exist?(REGISTRY_FILE)
      self
    end

    def state
      return {} unless File.exist?(STATE_FILE)

      parse_ini_file(STATE_FILE)
    end

    def update_state(section, key, value)
      ensure_directories
      current = state
      current[section] ||= {}
      current[section][key] = value.to_s
      current["HIVE"]["last_updated"] = Time.now.iso8601
      write_ini_file(STATE_FILE, current)
    end

    def registry
      return { workers: [], components: [] } unless File.exist?(REGISTRY_FILE)

      JSON.parse(File.read(REGISTRY_FILE), symbolize_names: true)
    rescue JSON::ParserError
      { workers: [], components: [] }
    end

    def register_worker(id:, type:, status: "idle", metadata: {})
      ensure_directories
      reg = registry
      reg[:workers] ||= []

      existing = reg[:workers].find { |w| w[:id] == id }
      if existing
        existing.merge!(type: type, status: status, metadata: metadata, updated_at: Time.now.iso8601)
      else
        reg[:workers] << {
          id: id,
          type: type,
          status: status,
          metadata: metadata,
          registered_at: Time.now.iso8601,
          updated_at: Time.now.iso8601
        }
      end

      save_registry(reg)
      update_state("WORKERS", "count", reg[:workers].size)
      update_state("WORKERS", "active", reg[:workers].count { |w| w[:status] == "active" })
    end

    def unregister_worker(id)
      reg = registry
      reg[:workers]&.reject! { |w| w[:id] == id }
      save_registry(reg)
      update_state("WORKERS", "count", reg[:workers]&.size || 0)
    end

    def register_component(name:, type:, path:, status: "available", metadata: {})
      ensure_directories
      reg = registry
      reg[:components] ||= []

      existing = reg[:components].find { |c| c[:name] == name }
      if existing
        existing.merge!(type: type, path: path, status: status, metadata: metadata, updated_at: Time.now.iso8601)
      else
        reg[:components] << {
          name: name,
          type: type,
          path: path,
          status: status,
          metadata: metadata,
          registered_at: Time.now.iso8601,
          updated_at: Time.now.iso8601
        }
      end

      save_registry(reg)
      update_state("COMPONENTS", "count", reg[:components].size)
    end

    def unregister_component(name)
      reg = registry
      reg[:components]&.reject! { |c| c[:name] == name }
      save_registry(reg)
      update_state("COMPONENTS", "count", reg[:components]&.size || 0)
    end

    def workers
      registry[:workers] || []
    end

    def components
      registry[:components] || []
    end

    def active_workers
      workers.select { |w| w[:status] == "active" }
    end

    def find_worker(id)
      workers.find { |w| w[:id] == id }
    end

    def find_component(name)
      components.find { |c| c[:name] == name }
    end

    # User management
    def github_username
      state.dig("USER", "github_username")
    end

    def github_username=(username)
      update_state("USER", "github_username", username)
      update_state("USER", "github_verified", "false")
      username
    end

    def user
      state["USER"] || {}
    end

    def confirm_github_access
      username = github_username
      return { success: false, error: "GitHub username not configured" } if username.nil? || username.empty?

      begin
        # Check if gh CLI is available
        gh_version = `gh --version 2>&1`
        unless $?.success?
          return { success: false, error: "GitHub CLI (gh) not installed" }
        end

        # Check authentication status
        auth_status = `gh auth status 2>&1`
        unless $?.success?
          return { success: false, error: "Not authenticated with GitHub CLI. Run 'gh auth login'" }
        end

        # Get the authenticated user
        authenticated_user = `gh api user --jq '.login' 2>&1`.strip
        unless $?.success?
          return { success: false, error: "Failed to verify GitHub user" }
        end

        # Verify username matches
        if authenticated_user.downcase != username.downcase
          return {
            success: false,
            error: "GitHub username mismatch",
            configured: username,
            authenticated: authenticated_user
          }
        end

        # Update verified status
        update_state("USER", "github_verified", "true")
        update_state("USER", "github_verified_at", Time.now.iso8601)

        {
          success: true,
          username: authenticated_user,
          verified_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: e.message }
      end
    end

    def github_verified?
      state.dig("USER", "github_verified") == "true"
    end

    def post_message(from:, to: nil, type:, payload: {})
      ensure_directories
      message = {
        id: "msg_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(4)}",
        from: from,
        to: to,
        type: type,
        payload: payload,
        created_at: Time.now.iso8601,
        read: false
      }

      message_file = File.join(MESSAGES_DIR, "#{message[:id]}.json")
      File.write(message_file, JSON.pretty_generate(message))
      message
    end

    def messages(for_worker: nil, unread_only: false)
      return [] unless Dir.exist?(MESSAGES_DIR)

      Dir.glob(File.join(MESSAGES_DIR, "*.json")).map do |file|
        JSON.parse(File.read(file), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end.compact.select do |msg|
        matches = true
        matches &&= (msg[:to].nil? || msg[:to] == for_worker) if for_worker
        matches &&= !msg[:read] if unread_only
        matches
      end.sort_by { |m| m[:created_at] }
    end

    def mark_message_read(message_id)
      message_file = File.join(MESSAGES_DIR, "#{message_id}.json")
      return false unless File.exist?(message_file)

      message = JSON.parse(File.read(message_file), symbolize_names: true)
      message[:read] = true
      message[:read_at] = Time.now.iso8601
      File.write(message_file, JSON.pretty_generate(message))
      true
    end

    def cleanup_old_messages(older_than: 24.hours.ago)
      return unless Dir.exist?(MESSAGES_DIR)

      Dir.glob(File.join(MESSAGES_DIR, "*.json")).each do |file|
        message = JSON.parse(File.read(file), symbolize_names: true)
        created = Time.parse(message[:created_at]) rescue nil
        FileUtils.rm_f(file) if created && created < older_than
      rescue JSON::ParserError
        FileUtils.rm_f(file)
      end
    end

    def status
      {
        hive_dir: HIVE_DIR.to_s,
        state: state,
        user: {
          github_username: github_username,
          github_verified: github_verified?
        },
        workers: {
          total: workers.size,
          active: active_workers.size,
          list: workers
        },
        components: {
          total: components.size,
          list: components
        },
        messages: {
          total: messages.size,
          unread: messages(unread_only: true).size
        }
      }
    end

    private

    def ensure_directories
      FileUtils.mkdir_p(HIVE_DIR)
      FileUtils.mkdir_p(WORKERS_DIR)
      FileUtils.mkdir_p(MESSAGES_DIR)
    end

    def initialize_state
      initial_state = {
        "HIVE" => {
          "initialized_at" => Time.now.iso8601,
          "last_updated" => Time.now.iso8601,
          "version" => "1.0"
        },
        "USER" => {
          "github_username" => "",
          "github_verified" => "false",
          "github_verified_at" => ""
        },
        "WORKERS" => {
          "count" => "0",
          "active" => "0"
        },
        "COMPONENTS" => {
          "count" => "0"
        }
      }
      write_ini_file(STATE_FILE, initial_state)
    end

    def initialize_registry
      initial_registry = {
        workers: [],
        components: [],
        created_at: Time.now.iso8601
      }
      save_registry(initial_registry)
    end

    def save_registry(reg)
      File.write(REGISTRY_FILE, JSON.pretty_generate(reg))
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
end

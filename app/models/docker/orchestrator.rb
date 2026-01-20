# frozen_string_literal: true

module Docker
  # Orchestrator - Manages Docker containers for MCP servers
  # Uses docker-compose to start/stop/monitor all services
  class Orchestrator
    RUNSPACE_ROOT = File.expand_path("~/Documents/RunSpace")
    COMPOSE_FILE = File.join(RUNSPACE_ROOT, "docker-compose.yml")
    LOG_FILE = File.join(RUNSPACE_ROOT, ".runspace", "docker.log")

    SERVICES = {
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

    class << self
      def docker_available?
        system("docker --version > /dev/null 2>&1")
      end

      def docker_running?
        system("docker info > /dev/null 2>&1")
      end

      def compose_file_exists?
        File.exist?(COMPOSE_FILE)
      end

      def ready?
        docker_available? && docker_running? && compose_file_exists?
      end

      # Start all MCP server containers
      def start_all
        return { success: false, error: "Docker not available" } unless docker_available?
        return { success: false, error: "Docker Desktop not running" } unless docker_running?
        return { success: false, error: "docker-compose.yml not found" } unless compose_file_exists?

        log("Starting all MCP server containers...")

        Dir.chdir(RUNSPACE_ROOT) do
          # Build images first
          log("Building Docker images...")
          build_output = `docker-compose build 2>&1`
          log(build_output)

          unless $?.success?
            return { success: false, error: "Docker build failed", output: build_output }
          end

          # Start containers
          log("Starting containers...")
          start_output = `docker-compose up -d 2>&1`
          log(start_output)

          unless $?.success?
            return { success: false, error: "Docker start failed", output: start_output }
          end
        end

        # Wait for health checks
        log("Waiting for services to be healthy...")
        health_results = wait_for_healthy(timeout: 120)

        {
          success: health_results[:all_healthy],
          services: health_results[:services],
          message: health_results[:all_healthy] ? "All services started" : "Some services failed to start"
        }
      end

      # Stop all MCP server containers
      def stop_all
        return { success: false, error: "Docker not available" } unless docker_available?

        log("Stopping all MCP server containers...")

        Dir.chdir(RUNSPACE_ROOT) do
          output = `docker-compose down 2>&1`
          log(output)

          {
            success: $?.success?,
            output: output
          }
        end
      end

      # Restart all containers
      def restart_all
        stop_all
        sleep 2
        start_all
      end

      # Get status of all services
      def status
        return { docker_available: false } unless docker_available?
        return { docker_available: true, docker_running: false } unless docker_running?

        services_status = {}

        SERVICES.each do |key, config|
          services_status[key] = service_status(config)
        end

        {
          docker_available: true,
          docker_running: true,
          compose_exists: compose_file_exists?,
          services: services_status,
          all_running: services_status.values.all? { |s| s[:running] },
          all_healthy: services_status.values.all? { |s| s[:healthy] }
        }
      end

      # Check individual service status
      def service_status(config)
        container_status = `docker inspect --format='{{.State.Status}}' #{config[:container]} 2>/dev/null`.strip
        running = container_status == "running"

        healthy = false
        if running
          begin
            require "net/http"
            uri = URI(config[:health_url])
            response = Net::HTTP.get_response(uri)
            healthy = response.code == "200"
          rescue StandardError
            healthy = false
          end
        end

        {
          name: config[:name],
          container: config[:container],
          port: config[:port],
          running: running,
          healthy: healthy,
          status: container_status.empty? ? "not created" : container_status
        }
      end

      # Wait for all services to be healthy
      def wait_for_healthy(timeout: 120)
        start_time = Time.now
        results = { all_healthy: false, services: {} }

        loop do
          all_healthy = true
          SERVICES.each do |key, config|
            svc_status = service_status(config)
            results[:services][key] = svc_status
            all_healthy = false unless svc_status[:healthy]
          end

          if all_healthy
            results[:all_healthy] = true
            break
          end

          if Time.now - start_time > timeout
            log("Timeout waiting for services to be healthy")
            break
          end

          sleep 5
        end

        results
      end

      # Get logs for a specific service
      def logs(service_key, lines: 100)
        config = SERVICES[service_key.to_sym]
        return nil unless config

        `docker logs --tail #{lines} #{config[:container]} 2>&1`
      end

      # Build images only (no start)
      def build_all
        return { success: false, error: "Docker not available" } unless ready?

        log("Building all Docker images...")

        Dir.chdir(RUNSPACE_ROOT) do
          output = `docker-compose build 2>&1`
          log(output)

          {
            success: $?.success?,
            output: output
          }
        end
      end

      # Pull latest base images
      def pull_images
        return { success: false, error: "Docker not available" } unless ready?

        log("Pulling base images...")

        Dir.chdir(RUNSPACE_ROOT) do
          output = `docker-compose pull 2>&1`
          log(output)

          {
            success: $?.success?,
            output: output
          }
        end
      end

      private

      def log(message)
        timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        log_dir = File.dirname(LOG_FILE)
        FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)

        File.open(LOG_FILE, "a") do |f|
          f.puts "[#{timestamp}] #{message}"
        end
      end
    end
  end
end

class DashboardController < ApplicationController
  def index
    @mcp_servers = McpServer.includes(:skills).order(:name)
    @skills = Skill.includes(:mcp_server).order(:name)
    @gems = SharedGem.order(:name)
    @ralph_wiggins = RalphWiggins.current

    @stats = {
      mcp_servers: {
        total: @mcp_servers.count,
        online: @mcp_servers.online.count,
        offline: @mcp_servers.offline.count,
        with_issues: @mcp_servers.with_issues.count
      },
      skills: {
        total: @skills.count,
        available: @skills.available.count,
        with_errors: @skills.with_errors.count
      },
      gems: {
        total: @gems.count,
        installed: @gems.installed.count,
        outdated: @gems.outdated.count,
        with_issues: @gems.with_issues.count
      },
      ralph_wiggins: {
        running: RalphWiggins.any_running?,
        running_count: Epoch.running.count,
        total_epochs: Epoch.all.count,
        status: @ralph_wiggins.state["status"],
        iteration: @ralph_wiggins.state["iteration"] || 0
      }
    }
  end

  def refresh_health
    McpServer.find_each(&:check_health!)
    SharedGem.find_each(&:check_status!)

    redirect_to dashboard_path, notice: "Health checks completed"
  end
end

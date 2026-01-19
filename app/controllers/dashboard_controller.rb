class DashboardController < ApplicationController
  def index
    @mcp_servers = McpServer.includes(:skills).order(:name)
    @skills = Skill.includes(:mcp_server).order(:name)
    @gems = SharedGem.order(:name)

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
      }
    }
  end

  def refresh_health
    McpServer.find_each(&:check_health!)
    SharedGem.find_each(&:check_status!)

    redirect_to dashboard_path, notice: "Health checks completed"
  end
end

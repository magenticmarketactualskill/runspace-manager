# frozen_string_literal: true

class McpServersController < ApplicationController
  before_action :set_mcp_server, only: %i[show edit update destroy connect disconnect refresh_capabilities]

  def index
    @mcp_servers = McpServer.all.order(created_at: :desc)
  end

  def show
  end

  def new
    @mcp_server = McpServer.new
  end

  def edit
  end

  def create
    @mcp_server = McpServer.new(mcp_server_params)

    if @mcp_server.save
      redirect_to @mcp_server, notice: "MCP Server was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @mcp_server.update(mcp_server_params)
      redirect_to @mcp_server, notice: "MCP Server was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @mcp_server.destroy!
    redirect_to mcp_servers_url, notice: "MCP Server was successfully deleted."
  end

  # Custom actions for MCP operations

  def connect
    connection = OpenStruct.new(
      id: @mcp_server.id,
      url: "ws://localhost:#{@mcp_server.port}",
      auth_type: @mcp_server.auth_type,
      auth_token: @mcp_server.auth_token,
      name: @mcp_server.name
    )

    begin
      client = McpSkillClientServer::Client::ConnectionManager.instance.connect(connection)
      @mcp_server.update!(status: "online", last_health_check_at: Time.current, last_error: nil)
      redirect_to @mcp_server, notice: "Connected to MCP Server."
    rescue McpSkillClientServer::Client::ConnectionError => e
      @mcp_server.update!(status: "error", last_error: e.message)
      redirect_to @mcp_server, alert: "Failed to connect: #{e.message}"
    end
  end

  def disconnect
    connection = OpenStruct.new(id: @mcp_server.id)
    McpSkillClientServer::Client::ConnectionManager.instance.disconnect(connection)
    @mcp_server.update!(status: "offline")
    redirect_to @mcp_server, notice: "Disconnected from MCP Server."
  end

  def refresh_capabilities
    connection = OpenStruct.new(id: @mcp_server.id)

    begin
      caps = McpSkillClientServer::Client::ConnectionManager.instance.refresh_capabilities(connection)

      # Update cached tools on the server
      @mcp_server.update!(
        cached_tools: caps[:tools],
        capabilities_updated_at: Time.current
      )

      # Sync skills from tools
      sync_skills_from_tools(caps[:tools])

      redirect_to @mcp_server, notice: "Capabilities refreshed. Found #{caps[:tools].size} tools."
    rescue McpSkillClientServer::Client::NotConnectedError
      redirect_to @mcp_server, alert: "Not connected to server. Connect first."
    rescue StandardError => e
      redirect_to @mcp_server, alert: "Failed to refresh: #{e.message}"
    end
  end

  private

  def set_mcp_server
    @mcp_server = McpServer.find(params[:id])
  end

  def mcp_server_params
    params.require(:mcp_server).permit(
      :name, :repository_url, :local_path, :port, :status,
      :auth_type, :auth_token, :description
    )
  end

  def sync_skills_from_tools(tools)
    tools.each do |tool|
      skill = @mcp_server.skills.find_or_initialize_by(name: tool["name"] || tool[:name])
      skill.update!(
        description: tool["description"] || tool[:description],
        input_schema: tool["inputSchema"] || tool[:inputSchema] || tool[:input_schema],
        status: "available"
      )
    end
  end
end

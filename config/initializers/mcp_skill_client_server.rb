# frozen_string_literal: true

# McpSkillClientServer Configuration
# This initializer configures the gem with Rails callbacks for database integration

McpSkillClientServer.configure do |config|
  # General settings
  config.logger = Rails.logger
  config.default_timeout = 30
  config.max_retries = 3

  # API Keys from credentials or environment
  config.anthropic_api_key = Rails.application.credentials.dig(:anthropic, :api_key) ||
                             ENV["ANTHROPIC_API_KEY"]
  config.openai_api_key = Rails.application.credentials.dig(:openai, :api_key) ||
                          ENV["OPENAI_API_KEY"]
  config.openrouter_api_key = Rails.application.credentials.dig(:openrouter, :api_key) ||
                              ENV["OPENROUTER_API_KEY"]
  config.ollama_host = ENV.fetch("OLLAMA_HOST", "http://localhost:11434")

  # MCP Server settings
  config.server_port = ENV.fetch("MCP_SERVER_PORT", 8080).to_i
  config.server_host = ENV.fetch("MCP_SERVER_HOST", "0.0.0.0")

  # Callback: Log tool calls to the database
  # Called when a tool is invoked (for logging/auditing)
  # direction: :inbound (external calling us) or :outbound (us calling external)
  config.tool_call_logger = ->(direction, tool_name, arguments, result, error: nil, connection: nil, user_id: nil) do
    Rails.logger.info "[MCP #{direction}] Tool: #{tool_name}, Args: #{arguments.inspect}"
    Rails.logger.error "[MCP #{direction}] Error: #{error}" if error

    # Optional: Create audit log record
    # McpToolCall.create!(
    #   direction: direction,
    #   tool_name: tool_name,
    #   arguments: arguments,
    #   result: result,
    #   error: error,
    #   mcp_server_connection_id: connection&.id,
    #   user_id: user_id
    # )
  end

  # Callback: Handle connection state changes
  # Called when MCP connection state changes
  # state: :connecting, :connected, :disconnected, :error
  config.connection_state_handler = ->(connection_id, state, error: nil) do
    Rails.logger.info "[MCP] Connection #{connection_id} state: #{state}"
    Rails.logger.error "[MCP] Connection error: #{error}" if error

    # Update connection record if using ActiveRecord
    # McpServerConnection.find_by(id: connection_id)&.update!(
    #   status: state,
    #   last_error: error,
    #   last_connected_at: state == :connected ? Time.current : nil
    # )
  end

  # Callback: Update cached capabilities on a connection
  config.capabilities_updater = ->(connection_id, tools:, resources:, prompts:) do
    Rails.logger.info "[MCP] Connection #{connection_id} capabilities updated: #{tools.size} tools"

    # Update cached tools on connection record
    # McpServerConnection.find_by(id: connection_id)&.update!(
    #   cached_tools: tools,
    #   cached_resources: resources,
    #   cached_prompts: prompts,
    #   capabilities_updated_at: Time.current
    # )
  end

  # Callback: Find a skill by slug
  # Returns a SkillDefinition or nil
  config.skill_finder = ->(slug, user: nil) do
    # Find skill from database
    # skill_record = Skill.enabled.find_by(slug: slug)
    # return nil unless skill_record
    # McpSkillClientServer::Skills::SkillDefinition.from_record(skill_record)

    # Placeholder - return nil until Skill model exists
    nil
  end

  # Callback: Find enabled connections for a user
  # Returns Array of connection objects
  config.connections_finder = ->(user_id) do
    # Return enabled connections for user
    # McpServerConnection.enabled.where(user_id: user_id).to_a

    # Placeholder - return empty array until model exists
    []
  end

  # Callback: Get local tools from the MCP server registry
  config.local_tool_provider = -> do
    McpSkillClientServer::Server::SkillRegistry.instance.to_mcp_tools
  end

  # Callback: Route an LLM request to a provider
  config.llm_router = ->(task, prompt, schema: nil, timeout: nil) do
    McpSkillClientServer::Llm::Router.route(task, prompt, schema: schema, timeout: timeout)
  end
end

# Register skills from the database as MCP tools on server startup
Rails.application.config.after_initialize do
  # Register system skills as MCP tools
  # Skill.system_skills.enabled.find_each do |skill|
  #   skill_def = McpSkillClientServer::Skills::SkillDefinition.from_record(skill)
  #   McpSkillClientServer::Server::SkillRegistry.instance.register(skill_def)
  # end

  Rails.logger.info "[MCP] McpSkillClientServer v#{McpSkillClientServer::VERSION} initialized"
end

# Clean up MCP connections on shutdown
at_exit do
  McpSkillClientServer::Client::ConnectionManager.instance.disconnect_all
rescue StandardError => e
  Rails.logger.warn "[MCP] Error during shutdown: #{e.message}"
end

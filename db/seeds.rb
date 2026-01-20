# Seed data for RunSpace Dashboard
# Run with: bin/rails db:seed

puts "Seeding MCP Servers..."

# MCP Servers from .runspace/code_structure.ini
mcp_servers_data = [
  {
    name: "TypeStore",
    repository_url: "https://github.com/magenticmarketactualskill/TypeStore.git",
    local_path: Rails.root.join("mcp_servers/TypeStore").to_s,
    port: 3001,
    status: "unknown",
    description: "API specification storage MCP server. Manages OpenAPI, JSON-RPC, GraphQL, gRPC, and AsyncAPI specs."
  },
  {
    name: "CollaborativeKanban",
    repository_url: "https://github.com/magenticmarketactualskill/CollaborativeKanban.git",
    local_path: Rails.root.join("mcp_servers/CollaborativeKanban").to_s,
    port: 3002,
    status: "unknown",
    description: "Kanban board MCP server with AI-powered task management, knowledge extraction, and LLM integration."
  },
  {
    name: "MagenticResources",
    repository_url: "https://github.com/magenticmarketactualskill/MagenticResources.git",
    local_path: Rails.root.join("mcp_servers/MagenticResources").to_s,
    port: 3003,
    status: "unknown",
    description: "Resource management MCP server for tracking human and AI agent resources, skills, and project allocations."
  }
]

mcp_servers_data.each do |server_data|
  server = McpServer.find_or_create_by!(name: server_data[:name]) do |s|
    s.repository_url = server_data[:repository_url]
    s.local_path = server_data[:local_path]
    s.port = server_data[:port]
    s.status = server_data[:status]
    s.description = server_data[:description]
  end
  puts "  Created MCP Server: #{server.name}"
end

puts "Seeding Skills..."

# Sample skills for each MCP Server
typestore = McpServer.find_by(name: "TypeStore")
if typestore
  [
    { name: "create_api_spec", description: "Create a new API specification" },
    { name: "list_api_specs", description: "List all API specifications" },
    { name: "get_api_spec", description: "Get details of a specific API spec" },
    { name: "validate_spec", description: "Validate an API specification format" },
    { name: "compare_versions", description: "Compare two versions of an API spec" }
  ].each do |skill_data|
    skill = Skill.find_or_create_by!(name: skill_data[:name], mcp_server: typestore) do |s|
      s.description = skill_data[:description]
      s.status = "available"
    end
    puts "  Created Skill: #{skill.name} (#{typestore.name})"
  end
end

kanban = McpServer.find_by(name: "CollaborativeKanban")
if kanban
  [
    { name: "create_card", description: "Create a new Kanban card" },
    { name: "move_card", description: "Move a card between columns" },
    { name: "assign_card", description: "Assign a card to a user" },
    { name: "extract_entities", description: "Extract entities from card content using AI" },
    { name: "suggest_relationships", description: "AI-powered relationship suggestions between cards" },
    { name: "analyze_board", description: "Analyze board performance and metrics" }
  ].each do |skill_data|
    skill = Skill.find_or_create_by!(name: skill_data[:name], mcp_server: kanban) do |s|
      s.description = skill_data[:description]
      s.status = "available"
    end
    puts "  Created Skill: #{skill.name} (#{kanban.name})"
  end
end

resources = McpServer.find_by(name: "MagenticResources")
if resources
  [
    { name: "list_resources", description: "List all available resources" },
    { name: "allocate_resource", description: "Allocate a resource to a project" },
    { name: "check_availability", description: "Check resource availability" },
    { name: "get_capacity", description: "Get resource capacity information" },
    { name: "assign_skill", description: "Assign a skill to a resource" }
  ].each do |skill_data|
    skill = Skill.find_or_create_by!(name: skill_data[:name], mcp_server: resources) do |s|
      s.description = skill_data[:description]
      s.status = "available"
    end
    puts "  Created Skill: #{skill.name} (#{resources.name})"
  end
end

puts "Seeding Gems..."

# Sample shared gems
gems_data = [
  {
    name: "llm_client",
    local_path: Rails.root.join("gem/llm_client").to_s,
    version: "0.1.0",
    status: "unknown",
    description: "LLM provider abstraction layer supporting OpenAI, Anthropic, Ollama, and OpenRouter."
  },
  {
    name: "entity_knowledge",
    local_path: Rails.root.join("gem/entity_knowledge").to_s,
    version: "0.1.0",
    status: "unknown",
    description: "Knowledge extraction and entity management for semantic understanding."
  },
  {
    name: "task-frame",
    local_path: Rails.root.join("gem/task-frame").to_s,
    version: "0.1.0",
    status: "unknown",
    description: "Multi-stage task lifecycle management framework."
  }
]

gems_data.each do |gem_data|
  gem_record = SharedGem.find_or_create_by!(name: gem_data[:name]) do |g|
    g.local_path = gem_data[:local_path]
    g.version = gem_data[:version]
    g.status = gem_data[:status]
    g.description = gem_data[:description]
  end
  puts "  Created Gem: #{gem_record.name}"
end

puts "Seeding complete!"
puts "  MCP Servers: #{McpServer.count}"
puts "  Skills: #{Skill.count}"
puts "  Gems: #{SharedGem.count}"

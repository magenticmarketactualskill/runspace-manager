# RunSpace

A workspace orchestrator that manages multiple repositories sharing components and operating seamlessly together.

## Overview

RunSpace coordinates development across related repositories by:
- Cloning and managing shared component repositories
- Launching VS Code instances with proper workspace configuration
- Providing MCP (Model Context Protocol) server integration for LLM support
- Providing arbitration:
    Does an error indicate a problem with a particular part?
        MCP Server
        Skill
        Gem
    Approriate tasks will be added to CollaborativeKanban
- Dashboard - Tracks Agent/Team/Group/LLM performance 

## Architecture

RunSpace shares its general architecture with [CollaborativeKanban](https://github.com/magenticmarketactualskill/CollaborativeKanban.git):
- **Rails App** - Ruby on Rails backend
- **SQLite** - Local database storage
- **LLM Support** - Integration with language models via MCP servers

## Directory Structure

```
RunSpace/
├── gem/              # Shared Ruby gems/components
├── mcp_servers/      # MCP server repositories
├── .runspace.ini     # Configuration file
└── README.md
```

## Prerequisites

- Ruby 3.x
- Rails 7.x
- SQLite3
- Git
- VS Code

## Installation

1. Clone RunSpace:
   ```bash
   git clone https://github.com/magenticmarketactualskill/RunSpace.git
   cd RunSpace
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Create configuration file:
   ```bash
   cp .runspace.ini.example .runspace.ini
   ```

## Configuration

Create `.runspace.ini` in the project root to specify MCP servers and other settings.

### Example `.runspace.ini`

```ini
[MCP SERVERS]
https://github.com/magenticmarketactualskill/TypeStore.git
https://github.com/magenticmarketactualskill/CollaborativeKanban.git
https://github.com/magenticmarketactualskill/MagenticResources.git
```

## Usage

```bash
# Start RunSpace
rails server

# Clone configured MCP servers
rake runspace:clone_servers

# Launch VS Code workspace
rake runspace:vscode
```

## Related Repositories

- [TypeStore](https://github.com/magenticmarketactualskill/TypeStore.git) - Type storage MCP server
- [CollaborativeKanban](https://github.com/magenticmarketactualskill/CollaborativeKanban.git) - Kanban board with shared architecture
- [MagenticResources](https://github.com/magenticmarketactualskill/MagenticResources.git) - Shared resources

## License

MIT

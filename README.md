# localprompt

A comprehensive local AI assistant with agents, swarm intelligence, memory, BYOK providers, MCP tools, web search, reasoning, and more.

## Features

- **Chat** - Interactive chat with local models
- **Agent Mode** - AI agents with roles that work as a team
- **Swarm Mode** - All models collaborate via Hive Mem
- **TUI** - Full terminal user interface
- **Memory** - Persistent memory (Hive Mem + Local Mem)
- **BYOK Providers** - OpenAI, Anthropic, Google, Ollama & more
- **MCP Support** - Model Context Protocol for tool integration
- **Web Search** - Built-in web search capabilities
- **Reasoning** - Chain-of-thought and step-by-step reasoning
- **Role Rotation** - Agent roles change over time

## Installation

```bash
pip install -e .
```

## Quick Start

```bash
# Chat with a local model
localprompt chat ~/.localprompt/models/*.gguf

# Agent mode with a system prompt
localprompt agent --role coder --model model.gguf

# Swarm mode - all models collaborate
localprompt swarm

# Start the TUI
localprompt tui

# Use a BYOK provider
localprompt chat --provider openai --api-key sk-... -m "Hello"
```

## Commands

| Command | Description |
|---------|-------------|
| `localprompt chat` | Chat with models (local or providers) |
| `localprompt agent` | Agent mode with role |
| `localprompt swarm` | Swarm mode with all models |
| `localprompt tui` | Terminal UI |
| `localprompt agent` | Agent mode |
| `localprompt download` | Download models |
| `localprompt models` | List models |
| `localprompt providers` | List/configure providers |
| `localprompt mcp` | MCP tool management |
| `localprompt memory` | Memory management |
| `localprompt hive` | Hive Mem operations |
| `localprompt config` | Configuration |
| `localprompt version` | Version info |

## Providers (BYOK)

LocalPrompt supports multiple AI providers. Configure with:

```bash
# OpenAI
localprompt providers --set openai --api-key sk-...

# Anthropic
localprompt providers --set anthropic --api-key sk-ant-...

# Google Gemini
localprompt providers --set google --api-key ai-...

# Ollama (local, no key)
localprompt providers --set ollama --base-url http://localhost:11434
```

## MCP

Model Context Protocol support for tool integration:

```bash
# Add an MCP server
localprompt mcp add filesystem --command npx --args -y @modelcontextprotocol/server-filesystem /tmp

# List MCP tools
localprompt mcp list

# Use MCP tools in agent mode
localprompt agent --role researcher --use-mcp
```

## Memory

- **Hive Mem** - Shared memory across all agents and sessions
- **Local Mem** - Per-agent private memory

```bash
# View Hive Mem
localprompt hive --view

# Search memory
localprompt memory search "project goals"

# Clear memory
localprompt memory clear
```

## Agent Roles

Agents can be assigned roles that define their behavior:

| Role | Description |
|------|-------------|
| coder | Software engineering and coding |
| researcher | Research and analysis |
| writer | Content creation and writing |
| critic | Review and critique |
| planner | Planning and strategy |
| executor | Task execution |
| generalist | General purpose |

Roles rotate over time in agent mode, giving each agent diverse capabilities.

import json
import os
import requests
from pathlib import Path
from typing import Any, Dict, List, Optional

from rich.console import Console
from rich.table import Table

from localprompt.utils import console


class MCPServer:
    def __init__(self, name: str, command: str, args: List[str] = None, env: Dict[str, str] = None):
        self.name = name
        self.command = command
        self.args = args or []
        self.env = env or {}
        self.tools: List[Dict[str, Any]] = []
        self._loaded = False

    def load_tools(self):
        if self._loaded:
            return
        self._loaded = True
        tools_file = Path.home() / ".localprompt" / "mcp" / self.name / "tools.json"
        if tools_file.exists():
            with open(tools_file, "r") as f:
                self.tools = json.load(f).get("tools", [])

    def get_tools(self) -> List[Dict[str, Any]]:
        self.load_tools()
        return self.tools


class MCPManager:
    def __init__(self):
        self.servers: Dict[str, MCPServer] = {}
        self.mcp_dir = Path.home() / ".localprompt" / "mcp"
        self._load_config()

    def _load_config(self):
        config_file = self.mcp_dir / "servers.json"
        if config_file.exists():
            with open(config_file, "r") as f:
                data = json.load(f)
            for name, server_data in data.items():
                self.servers[name] = MCPServer(
                    name=name,
                    command=server_data.get("command", ""),
                    args=server_data.get("args", []),
                    env=server_data.get("env", {}),
                )

    def _save_config(self):
        self.mcp_dir.mkdir(parents=True, exist_ok=True)
        data = {name: {"command": s.command, "args": s.args, "env": s.env} for name, s in self.servers.items()}
        with open(self.mcp_dir / "servers.json", "w") as f:
            json.dump(data, f, indent=2)

    def add_server(self, name: str, command: str, args: List[str] = None, env: Dict[str, str] = None):
        self.servers[name] = MCPServer(name=name, command=command, args=args, env=env)
        self._save_config()

    def remove_server(self, name: str):
        if name in self.servers:
            del self.servers[name]
            self._save_config()

    def list_servers(self) -> List[str]:
        return list(self.servers.keys())

    def get_tools(self) -> Dict[str, List[Dict[str, Any]]]:
        tools = {}
        for name, server in self.servers.items():
            server.load_tools()
            tools[name] = server.get_tools()
        return tools

    def call_tool(self, server_name: str, tool_name: str, **kwargs) -> Any:
        server = self.servers.get(server_name)
        if not server:
            raise ValueError(f"MCP server not found: {server_name}")
        server.load_tools()
        for tool in server.get_tools():
            if tool.get("name") == tool_name:
                return self._execute_tool(server, tool, **kwargs)
        raise ValueError(f"Tool not found: {tool_name}")

    def _execute_tool(self, server: MCPServer, tool: Dict[str, Any], **kwargs) -> Any:
        tool_type = tool.get("inputSchema", {}).get("type", "object")
        if tool_type == "object":
            result = requests.post(
                f"http://localhost:8080/mcp/{server.name}/{tool['name']}",
                json=kwargs,
                timeout=30,
            )
            if result.status_code == 200:
                return result.json()
            return {"error": f"HTTP {result.status_code}"}
        return {"error": "Unsupported tool type"}

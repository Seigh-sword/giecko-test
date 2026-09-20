import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt, Confirm

from localprompt.config import load_config, save_config, get_models_dir, discover_models
from localprompt.model import ModelRunner
from localprompt.agent import Agent, RoleType, AgentRole, ROLE_DESCRIPTIONS
from localprompt.memory import MemoryManager, HiveMem, LocalMem
from localprompt.utils import console, format_file_size


class AgentManager:
    """Manages AI agents with roles and team coordination."""

    def __init__(self, config: Optional[dict] = None):
        self.config = config or load_config()
        self.agents: Dict[str, Agent] = {}
        self.hive_mem = HiveMem(self.config.get("hive_mem_file", str(Path.home() / ".localprompt" / "hive_mem.json")))
        self._role_rotation_interval = 300  # 5 minutes
        self._last_rotation = time.time()

    def create_agent(self, name: str, model_path: str, role: RoleType = RoleType.GENERALIST) -> Agent:
        runner = ModelRunner(model_path, self.config)
        runner.load()
        agent = Agent(name=name, model_path=model_path, role=role)
        agent.runner = runner
        self.agents[name] = agent
        self._save_agents()
        return agent

    def remove_agent(self, name: str):
        if name in self.agents:
            if self.agents[name].runner:
                self.agents[name].runner.unload()
            del self.agents[name]
            self._save_agents()

    def get_agent(self, name: str) -> Optional[Agent]:
        return self.agents.get(name)

    def list_agents(self) -> List[Agent]:
        return list(self.agents.values())

    def rotate_roles(self):
        """Rotate agent roles over time."""
        now = time.time()
        if now - self._last_rotation < self._role_rotation_interval:
            return
        self._last_rotation = now
        roles = list(RoleType)
        for i, agent in enumerate(self.agents.values()):
            new_role = roles[(i + int(now // self._role_rotation_interval)) % len(roles)]
            old_role = agent.role
            if old_role != new_role:
                console.print(f"[yellow]{agent.name}[/yellow]: [cyan]{old_role.value}[/cyan] -> [green]{new_role.value}[/green]")
                agent.role = new_role
        self._save_agents()

    def assign_role(self, agent_name: str, role: RoleType):
        if agent_name in self.agents:
            self.agents[agent_name].role = role
            self._save_agents()

    def team_chat(self, message: str, topic: str = "general") -> Dict[str, str]:
        """Send a message to all agents and collect responses."""
        self.rotate_roles()
        responses = {}
        self.hive_mem.store(f"topic_{topic}", {"message": message, "timestamp": time.time()})

        for name, agent in self.agents.items():
            if agent.runner is None:
                continue
            mem = self.get_agent_memory(name)
            context = self._build_context(agent, message)
            response = self._generate(agent, context)
            responses[name] = response
            agent.conversation.append({"role": "user", "content": message})
            agent.conversation.append({"role": "assistant", "content": response})
            agent.last_active = time.time()
            agent.total_tasks += 1
            mem.store("last_task", {"message": message, "response": response, "timestamp": time.time()})

        self.hive_mem.sync()
        self._save_agents()
        return responses

    def _build_context(self, agent: Agent, message: str) -> str:
        context_parts = []
        context_parts.append(f"You are {agent.name}, a {agent.role.value} agent. {agent.role_description}")
        recent_mem = agent.memory.search("last_task")
        if recent_mem:
            context_parts.append(f"Recent context: {recent_mem[-1]['value']}")
        hive_data = self.hive_mem.search(message[:50])
        if hive_data:
            context_parts.append(f"Team context: {[h['value'] for h in hive_data[:3]]}")
        if agent.conversation:
            for msg in agent.conversation[-4:]:
                context_parts.append(f"{msg['role']}: {msg['content']}")
        context_parts.append(f"User: {message}")
        return "\n".join(context_parts)

    def _generate(self, agent: Agent, prompt: str) -> str:
        if agent.runner is None:
            return f"[Error: {agent.name} has no model loaded]"
        result = agent.runner.generate_full(prompt, max_tokens=256)
        return result.text

    def get_agent_memory(self, agent_name: str) -> LocalMem:
        agent = self.get_agent(agent_name)
        if agent and agent.memory:
            return agent.memory
        return LocalMem(agent_name)

    def _save_agents(self):
        agents_dir = Path.home() / ".localprompt" / "agents"
        agents_dir.mkdir(parents=True, exist_ok=True)
        data = {name: agent.to_dict() for name, agent in self.agents.items()}
        with open(agents_dir / "agents.json", "w") as f:
            json.dump(data, f, indent=2)

    def _load_agents(self):
        agents_file = Path.home() / ".localprompt" / "agents" / "agents.json"
        if agents_file.exists():
            with open(agents_file, "r") as f:
                data = json.load(f)
            for name, agent_data in data.items():
                agent = Agent.from_dict(agent_data)
                self.agents[name] = agent

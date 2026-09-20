import json
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional

from rich.console import Console
from rich.text import Text

from localprompt.config import load_config, get_models_dir, discover_models
from localprompt.memory import HiveMem, LocalMem, MemoryManager
from localprompt.utils import console, format_file_size


class RoleType(str, Enum):
    CODER = "coder"
    RESEARCHER = "researcher"
    WRITER = "writer"
    CRITIC = "critic"
    PLANNER = "planner"
    EXECUTOR = "executor"
    GENERALIST = "generalist"


ROLE_DESCRIPTIONS = {
    RoleType.CODER: "Software engineering, coding, debugging, and code review",
    RoleType.RESEARCHER: "Research, analysis, fact-finding, and deep investigation",
    RoleType.WRITER: "Content creation, storytelling, and structured writing",
    RoleType.CRITIC: "Review, critique, quality assurance, and improvement",
    RoleType.PLANNER: "Strategic planning, architecture, and task decomposition",
    RoleType.EXECUTOR: "Task execution, automation, and implementation",
    RoleType.GENERALIST: "General-purpose assistance across all domains",
}


@dataclass
class AgentRole:
    role_type: RoleType
    description: str = ""
    priority: int = 1
    active: bool = True


@dataclass
class Agent:
    name: str
    model_path: Optional[str] = None
    role: RoleType = RoleType.GENERALIST
    memory: Optional[LocalMem] = None
    runner: Optional[Any] = None
    conversation: List[Dict[str, str]] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    last_active: float = field(default_factory=time.time)
    total_tasks: int = 0

    def __post_init__(self):
        if self.memory is None:
            self.memory = LocalMem(self.name)

    @property
    def role_description(self) -> str:
        return ROLE_DESCRIPTIONS.get(self.role, "General purpose agent")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "model_path": self.model_path,
            "role": self.role.value,
            "conversation": self.conversation,
            "created_at": self.created_at,
            "last_active": self.last_active,
            "total_tasks": self.total_tasks,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Agent":
        return cls(
            name=data["name"],
            model_path=data.get("model_path"),
            role=RoleType(data.get("role", "generalist")),
            conversation=data.get("conversation", []),
            created_at=data.get("created_at", time.time()),
            last_active=data.get("last_active", time.time()),
            total_tasks=data.get("total_tasks", 0),
        )

import json
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from rich.console import Console

console = Console()


class Memory:
    """Base memory class."""

    def __init__(self, name: str = "default"):
        self.name = name
        self._data: Dict[str, Any] = {}
        self._history: List[Dict[str, Any]] = []

    def store(self, key: str, value: Any):
        self._data[key] = {"value": value, "timestamp": time.time()}
        self._history.append({"action": "store", "key": key, "timestamp": time.time()})

    def retrieve(self, key: str) -> Optional[Any]:
        if key in self._data:
            return self._data[key]["value"]
        return None

    def delete(self, key: str):
        if key in self._data:
            del self._data[key]
            self._history.append({"action": "delete", "key": key, "timestamp": time.time()})

    def keys(self) -> List[str]:
        return list(self._data.keys())

    def get_all(self) -> Dict[str, Any]:
        return {k: v["value"] for k, v in self._data.items()}

    def search(self, query: str) -> List[Dict[str, Any]]:
        results = []
        query_lower = query.lower()
        for key, entry in self._data.items():
            if query_lower in str(key).lower() or query_lower in str(entry["value"]).lower():
                results.append({"key": key, "value": entry["value"], "timestamp": entry["timestamp"]})
        return results

    def to_dict(self) -> Dict[str, Any]:
        return {"data": self._data, "history": self._history}

    def from_dict(self, data: Dict[str, Any]):
        self._data = data.get("data", {})
        self._history = data.get("history", [])


class HiveMem(Memory):
    """Shared memory across all agents - the Hive Mind."""

    def __init__(self, filepath: Optional[str] = None):
        super().__init__("hive")
        self.filepath = filepath or str(Path.home() / ".localprompt" / "hive_mem.json")
        self._load()

    def _load(self):
        if Path(self.filepath).exists():
            try:
                with open(self.filepath, "r") as f:
                    data = json.load(f)
                    self.from_dict(data)
            except (json.JSONDecodeError, KeyError):
                pass

    def save(self):
        Path(self.filepath).parent.mkdir(parents=True, exist_ok=True)
        with open(self.filepath, "w") as f:
            json.dump(self.to_dict(), f, indent=2, default=str)

    def sync(self):
        self.save()


class LocalMem(Memory):
    """Per-agent private memory."""

    def __init__(self, agent_name: str, filepath: Optional[str] = None):
        super().__init__(f"local_{agent_name}")
        self.agent_name = agent_name
        self.filepath = filepath or str(Path.home() / ".localprompt" / "agents" / f"{agent_name}_memory.json")
        self._load()

    def _load(self):
        if Path(self.filepath).exists():
            try:
                with open(self.filepath, "r") as f:
                    data = json.load(f)
                    self.from_dict(data)
            except (json.JSONDecodeError, KeyError):
                pass

    def save(self):
        Path(self.filepath).parent.mkdir(parents=True, exist_ok=True)
        with open(self.filepath, "w") as f:
            json.dump(self.to_dict(), f, indent=2, default=str)


class MemoryManager:
    """Manages all memory instances."""

    def __init__(self, config: Optional[dict] = None):
        self.config = config or {}
        self.hive = HiveMem(self.config.get("hive_mem_file"))
        self.agent_memories: Dict[str, LocalMem] = {}

    def get_agent_memory(self, agent_name: str) -> LocalMem:
        if agent_name not in self.agent_memories:
            self.agent_memories[agent_name] = LocalMem(agent_name)
        return self.agent_memories[agent_name]

    def search_all(self, query: str) -> List[Dict[str, Any]]:
        results = []
        results.append({"source": "hive", "results": self.hive.search(query)})
        for name, mem in self.agent_memories.items():
            results.append({"source": name, "results": mem.search(query)})
        return results

    def save_all(self):
        self.hive.save()
        for mem in self.agent_memories.values():
            mem.save()

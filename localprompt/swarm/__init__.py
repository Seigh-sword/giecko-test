import time
import threading
from typing import Dict, List, Optional

from localprompt.model import ModelRunner, GenerationResult
from localprompt.agent import Agent, RoleType
from localprompt.utils import console


class SwarmCoordinator:
    """Coordinates multiple models in swarm mode."""

    def __init__(self, models: List[str], config: Optional[dict] = None):
        self.config = config or {}
        self.models = models
        self.runners: Dict[str, ModelRunner] = {}
        self.hive_mem = {}
        self._lock = threading.Lock()
        self._running = False
        self._threads: List[threading.Thread] = []

    def start(self):
        self._running = True
        for model_path in self.models:
            runner = ModelRunner(model_path, self.config)
            try:
                runner.load()
                name = ModelRunner.__repr__(runner).split("name=")[-1].split(",")[0] if "name=" in str(runner) else ModelRunner.__repr__(runner).split("(")[-1].split(",")[0] if "(" in str(runner) else Path(model_path).stem
                self.runners[name] = runner
                console.print(f"[green]Loaded: {name}[/green]")
            except Exception as e:
                console.print(f"[red]Failed to load {model_path}: {e}[/red]")

    def broadcast(self, message: str) -> Dict[str, str]:
        results = {}
        for name, runner in self.runners.items():
            try:
                result = runner.generate_full(message, max_tokens=128)
                results[name] = result.text
                with self._lock:
                    self.hive_mem[f"{name}_{time.time()}"] = message
            except Exception as e:
                results[name] = f"[Error: {e}]"
        return results

    def consult(self, question: str, specialist_roles: Dict[str, List[str]]) -> Dict[str, str]:
        results = {}
        for model_name, roles in specialist_roles.items():
            if model_name in self.runners:
                prompt = f"You are a {', '.join(roles)}. {question}"
                result = self.runners[model_name].generate_full(prompt, max_tokens=256)
                results[model_name] = result.text
        return results

    def hive_sync(self):
        with self._lock:
            if len(self.hive_mem) > 1000:
                sorted_mem = sorted(self.hive_mem.items(), key=lambda x: x[0])
                self.hive_mem = dict(sorted_mem[-500:])

    def stop(self):
        self._running = False
        for runner in self.runners.values():
            runner.unload()
        self.runners.clear()

    def __del__(self):
        self.stop()

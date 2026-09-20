import time
from typing import List, Optional, Dict, Any

from rich.console import Console

from localprompt.utils import console


class Reasoner:
    """Chain-of-thought reasoning engine."""

    def __init__(self):
        self.steps: List[Dict[str, Any]] = []
        self.start_time = time.time()

    def reset(self):
        self.steps = []
        self.start_time = time.time()

    def think(self, step: str, result: Optional[str] = None) -> str:
        step_data = {
            "step": step,
            "result": result,
            "timestamp": time.time(),
            "elapsed": time.time() - self.start_time,
        }
        self.steps.append(step_data)
        console.print(f"[cyan]Thinking: {step}[/cyan]")
        if result:
            console.print(f"[dim]Result: {result}[/dim]")
        return step_data

    def reason(self, question: str, model_runner=None, max_iterations: int = 5, **kwargs) -> str:
        """Step-by-step reasoning with optional model assistance."""
        self.reset()
        current_question = question

        for i in range(max_iterations):
            self.think(f"Step {i+1}: Analyze the problem")

            if model_runner:
                prompt = f"Question: {current_question}\n\nThink step by step."
                result = model_runner.generate_full(prompt, max_tokens=256, **kwargs)
                self.think(f"Step {i+1}: Model reasoning", result.text)
                current_question = result.text
            else:
                break

            if "therefore" in current_question.lower() or "conclusion" in current_question.lower() or i >= max_iterations - 1:
                break

        self.think("Final synthesis")
        return self.synthesize()

    def synthesize(self) -> str:
        summary_parts = []
        for step in self.steps:
            if step.get("result"):
                summary_parts.append(step["result"])
        return "\n\n".join(summary_parts) if summary_parts else "Reasoning complete."

    def get_steps(self) -> List[Dict[str, Any]]:
        return self.steps

    def to_dict(self) -> Dict[str, Any]:
        return {"steps": self.steps, "duration": time.time() - self.start_time}

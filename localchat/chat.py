import json
from pathlib import Path
from datetime import datetime
from typing import List, Tuple, Optional

from rich.panel import Panel
from rich.prompt import Prompt

from localchat.config import load_config, discover_models
from localchat.model import ModelRunner
from localchat.templates import get_template, format_chat
from localchat.utils import console


class ChatSession:
    def __init__(self, model_path: str, system_message: str = "", config: Optional[dict] = None):
        self.config = config or load_config()
        self.model_path = model_path
        self.system_message = system_message
        self.conversation: List[Tuple[str, str]] = []
        self.runner = ModelRunner(model_path, self.config)
        self.conversation_file: Optional[Path] = None

    def start(self, save_conversation: bool = False, convo_name: Optional[str] = None):
        console.print()
        console.print(Panel.fit(
            f"[bold cyan]LocalChat[/bold cyan] - Local AI Assistant\n"
            f"Model: [green]{self.model_path}[/green]\n"
            f"Type [yellow]/help[/yellow] for commands, "
            f"[yellow]/clear[/yellow] to reset, "
            f"[yellow]/exit[/yellow] to quit",
            title="Welcome",
            border_style="blue",
        ))
        console.print()

        if save_conversation:
            convo_dir = Path.home() / ".localchat" / "conversations"
            convo_dir.mkdir(parents=True, exist_ok=True)
            name = convo_name or datetime.now().strftime("%Y%m%d_%H%M%S")
            self.conversation_file = convo_dir / f"{name}.json"

        self.runner.load()
        self._print_model_info()

        if self.system_message:
            console.print(f"[dim]System: {self.system_message}[/dim]")
            console.print()

        self._chat_loop()

    def _print_model_info(self):
        info = self.runner.model_info
        if info:
            console.print(f"[bold]Model:[/bold] {info.name}")
            console.print(f"[bold]Parameters:[/bold] {info.param_count}")
            console.print(f"[bold]Context:[/bold] {info.context_size}")
            console.print()

    def _chat_loop(self):
        while True:
            try:
                user_input = Prompt.ask("[bold green]You[/bold green]")
            except EOFError:
                console.print("\n[dim]Goodbye![/dim]")
                break

            if not user_input.strip():
                continue

            if user_input.strip() == "/exit" or user_input.strip() == "/quit":
                if self.conversation_file:
                    self._save_conversation()
                console.print("[dim]Goodbye![/dim]")
                break

            if user_input.strip() == "/clear":
                self.conversation = []
                console.print("[dim]Conversation cleared.[/dim]")
                continue

            if user_input.strip() == "/history":
                self._print_history()
                continue

            if user_input.strip() == "/help":
                self._print_help()
                continue

            if user_input.strip().startswith("/save"):
                parts = user_input.strip().split(" ", 1)
                name = parts[1] if len(parts) > 1 else datetime.now().strftime("%Y%m%d_%H%M%S")
                self._save_conversation(name=name)
                continue

            if user_input.strip().startswith("/load"):
                parts = user_input.strip().split(" ", 1)
                if len(parts) > 1:
                    self._load_conversation(parts[1])
                else:
                    console.print("[yellow]Usage: /load <name>[/yellow]")
                continue

            if user_input.strip().startswith("/model"):
                parts = user_input.strip().split(" ", 1)
                if len(parts) > 1:
                    self._switch_model(parts[1])
                else:
                    self._list_models()
                continue

            self._respond(user_input)

    def _respond(self, user_message: str):
        template = get_template(self.model_path)
        formatted_prompt = format_chat(template, self.system_message, self.conversation, user_message)

        token_count = self.runner.count_tokens(formatted_prompt)
        console.print(f"[dim]Prompt: {token_count} tokens[/dim]")

        console.print("[bold blue]Assistant:[/bold blue] ", end="")

        full_response = ""
        start_time = None
        tokens_output = 0

        for chunk in self.runner.generate(formatted_prompt, stream=self.config.get("streaming", True)):
            if start_time is None:
                start_time = __import__("time").time()
            console.print(chunk, end="")
            full_response += chunk
            tokens_output += 1

        elapsed = __import__("time").time() - (start_time or 0)
        console.print()

        if elapsed > 0:
            tps = tokens_output / elapsed
            console.print(f"[dim]Generated {tokens_output} tokens in {elapsed:.1f}s ({tps:.1f} tok/s)[/dim]")

        self.conversation.append((user_message, full_response))

        if self.conversation_file:
            self._save_conversation()

    def _switch_model(self, model_path: str):
        from localchat.model import ModelRunner as MR
        console.print(f"[yellow]Switching model to {model_path}...[/yellow]")
        self.runner.unload()
        self.runner = MR(model_path, self.config)
        self.runner.load()
        self._print_model_info()

    def _list_models(self):
        models = discover_models()
        if not models:
            console.print("[yellow]No models found.[/yellow]")
            return
        for m in models:
            console.print(f"  [green]{m['name']}[/green] ({m['size_gb']}GB) - {m['path']}")

    def _print_history(self):
        if not self.conversation:
            console.print("[dim]No conversation yet.[/dim]")
            return
        for i, (user, assistant) in enumerate(self.conversation):
            console.print(f"\n[bold][{i+1}][/bold] [green]You:[/green] {user}")
            truncated = assistant[:200] + "..." if len(assistant) > 200 else assistant
            console.print(f"        [blue]AI:[/blue] {truncated}")

    def _print_help(self):
        console.print("""
[bold]Commands:[/bold]
  /help           Show this help message
  /clear          Clear conversation history
  /history        Show conversation history
  /save [name]    Save conversation
  /load <name>    Load conversation
  /model [path]   Switch model or list models
  /exit           Exit the chat
        """)

    def _save_conversation(self, name: Optional[str] = None):
        if not self.conversation_file:
            return
        if name:
            self.conversation_file = self.conversation_file.parent / f"{name}.json"
        data = {
            "model": self.model_path,
            "system": self.system_message,
            "conversation": self.conversation,
            "saved_at": datetime.now().isoformat(),
        }
        with open(self.conversation_file, "w") as f:
            json.dump(data, f, indent=2)
        console.print(f"[dim]Saved to {self.conversation_file}[/dim]")

    def _load_conversation(self, name: str):
        convo_dir = Path.home() / ".localchat" / "conversations"
        path = convo_dir / f"{name}.json"
        if not path.exists():
            console.print(f"[red]Conversation '{name}' not found.[/red]")
            return
        with open(path, "r") as f:
            data = json.load(f)
        self.conversation = data.get("conversation", [])
        self.system_message = data.get("system", "")
        console.print(f"[green]Loaded conversation '{name}' ({len(self.conversation)} messages)[/green]")

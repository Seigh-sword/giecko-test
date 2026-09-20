import click
import json
import sys
import os

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt

from localprompt import __version__
from localprompt.config import (
    load_config,
    save_config,
    get_models_dir,
    discover_models,
)
from localprompt.model import ModelRunner, GenerationResult
from localprompt.utils import console


@click.group()
@click.option("--config", "-c", type=click.Path(exists=True), help="Path to config file")
@click.pass_context
def cli(ctx, config):
    if config:
        cfg = json.load(open(config))
        save_config(cfg)
    ctx.ensure_object(dict)
    ctx.obj["config"] = load_config()


@cli.command("chat")
@click.argument("model_path", required=False, default=None)
@click.option("--system", "-s", default="", help="System message")
@click.option("--prompt", "-p", default=None, help="Single prompt to run and exit")
@click.option("--max-tokens", "-m", default=512, help="Max tokens")
@click.option("--temperature", "-t", default=None, type=float, help="Temperature")
@click.option("--top-p", default=None, type=float, help="Top P")
@click.option("--provider", default=None, help="Provider name (BYOK)")
@click.option("--api-key", default=None, help="API key for provider")
@click.pass_context
def chat(ctx, model_path, system, prompt, max_tokens, temperature, top_p, provider, api_key):
    config = ctx.obj["config"]

    if provider:
        _chat_with_provider(model_path, system, prompt, max_tokens, temperature, provider, api_key, config)
        return

    if model_path is None:
        model_path = config.get("default_model")
    if model_path is None:
        models = discover_models()
        if models:
            model_path = models[0]["path"]
            console.print(f"[yellow]Using default model: {model_path}[/yellow]")
        else:
            console.print("[red]No model specified and no models found.[/red]")
            console.print("[yellow]Use: localprompt download <model_id>[/yellow]")
            sys.exit(1)

    if prompt is not None:
        runner = ModelRunner(model_path, config)
        runner.load()
        _run_single_prompt(runner, prompt, system, max_tokens, temperature, top_p)
        runner.unload()
        return

    _interactive_chat(model_path, system, config)


def _chat_with_provider(model_path, system, prompt, max_tokens, temperature, provider, api_key, config):
    from localprompt.providers import get_provider, ProviderConfig
    provider_config = ProviderConfig(
        name=provider,
        api_key=api_key or config.get("providers", {}).get(provider, {}).get("api_key"),
        model=model_path,
    )
    prov = get_provider(provider, provider_config)
    if not prov.is_available():
        console.print(f"[red]Provider {provider} not available. Check API key.[/red]")
        sys.exit(1)

    if prompt:
        result = prov.chat([{"role": "user", "content": prompt}], max_tokens=max_tokens, temperature=temperature or config.get("temperature", 0.7))
        console.print(result)
    else:
        console.print("[green]Provider chat mode (type /exit to quit)[/green]")
        while True:
            try:
                msg = Prompt.ask("You")
            except EOFError:
                break
            if msg.strip() == "/exit":
                break
            result = prov.chat([{"role": "user", "content": msg}], max_tokens=max_tokens, temperature=temperature or config.get("temperature", 0.7))
            console.print(f"[blue]Assistant:[/blue] {result}")


def _run_single_prompt(runner, prompt, system, max_tokens, temperature, top_p):
    from localprompt.templates import get_template, format_chat
    template = get_template(runner.model_path)
    formatted = format_chat(template, system, [], prompt)
    console.print("[bold blue]Assistant:[/bold blue] ", end="")
    full = ""
    for chunk in runner.generate(formatted, max_tokens=max_tokens, temperature=temperature, top_p=top_p, stream=True):
        console.print(chunk, end="")
        full += chunk
    console.print()


def _interactive_chat(model_path, system, config):
    from localprompt.model import ModelRunner
    from localprompt.chat import ChatSession
    session = ChatSession(model_path, system_message=system, config=config)
    session.start()


@cli.command("agent")
@click.argument("model_path", required=False, default=None)
@click.option("--role", "-r", default="generalist", help="Agent role")
@click.option("--name", "-n", default=None, help="Agent name")
@click.option("--prompt", "-p", default=None, help="Single prompt")
@click.option("--max-tokens", "-m", default=256, help="Max tokens")
@click.pass_context
def agent(ctx, model_path, role, name, prompt, max_tokens):
    config = ctx.obj["config"]
    from localprompt.agent import RoleType, Agent
    from localprompt.agent.manager import AgentManager

    am = AgentManager(config)

    if model_path is None:
        models = discover_models()
        if models:
            model_path = models[0]["path"]
        else:
            console.print("[red]No model found. Download one first.[/red]")
            sys.exit(1)

    agent_name = name or f"agent_{role}"
    if agent_name not in am.agents:
        console.print(f"[cyan]Creating agent {agent_name} with role {role}[/cyan]")
        am.create_agent(agent_name, model_path, RoleType(role))
    else:
        console.print(f"[cyan]Using existing agent {agent_name}[/cyan]")

    agent = am.get_agent(agent_name)

    if prompt:
        context = am._build_context(agent, prompt)
        result = agent.runner.generate_full(context, max_tokens=max_tokens)
        console.print(f"[green]{agent.name}:[/green] {result.text}")
        return

    console.print(f"[bold]Agent {agent_name} ({role})[/bold] - type /exit to quit")
    while True:
        try:
            msg = Prompt.ask(f"[{agent_name}]")
        except EOFError:
            console.print("[dim]Goodbye![/dim]")
            break
        if msg.strip() == "/exit":
            break
        if msg.strip() == "/role":
            am.rotate_roles()
            continue
        am.team_chat(msg)


@cli.command("swarm")
@click.option("--max-tokens", "-m", default=128, help="Max tokens per model")
@click.option("--topic", "-t", default="general", help="Swarm topic")
@click.pass_context
def swarm(ctx, max_tokens, topic):
    config = ctx.obj["config"]
    from localprompt.swarm import SwarmCoordinator

    models = discover_models()
    if not models:
        console.print("[red]No models found. Download models first.[/red]")
        sys.exit(1)

    model_paths = [m["path"] for m in models]
    coordinator = SwarmCoordinator(model_paths, config)
    console.print(f"[green]Starting swarm with {len(model_paths)} models[/green]")
    coordinator.start()

    while True:
        try:
            msg = Prompt.ask("[swarm]")
        except EOFError:
            break
        if msg.strip() == "/exit":
            break
        if msg.strip() == "/sync":
            coordinator.hive_sync()
            console.print("[green]Hive synced![/green]")
            continue
        results = coordinator.broadcast(msg)
        for name, response in results.items():
            console.print(f"[bold]{name}:[/bold] {response[:200]}")

    coordinator.stop()


@cli.command("tui")
def start_tui():
    from localprompt.tui import LocalPromptTUI
    config = load_config()
    from localprompt.model import ModelRunner
    from localprompt.agent import RoleType
    from localprompt.agent.manager import AgentManager

    runner = None
    manager = None

    models = discover_models(config)
    if models:
        runner = ModelRunner(models[0]["path"], config)
        runner.load()
    manager = AgentManager(config)

    def _run(stdscr):
        tui = LocalPromptTUI(stdscr, manager, runner)
        tui.run()

    import curses
    curses.wrapper(_run)

    if runner:
        runner.unload()


@cli.command("eval")
@click.argument("model_path")
@click.argument("prompt")
@click.option("--max-tokens", "-m", default=128, help="Max tokens")
@click.option("--temperature", "-t", default=None, type=float, help="Temperature")
@click.pass_context
def eval_cmd(ctx, model_path, prompt, max_tokens, temperature):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)
    runner.load()
    result = runner.generate_full(prompt, max_tokens=max_tokens, temperature=temperature)
    console.print(result.text)
    console.print()
    console.print(f"[dim]Tokens: {result.tokens_predicted} predicted, {result.tokens_evaluated} evaluated[/dim]")
    console.print(f"[dim]Time: {result.total_duration:.2f}s, {result.tokens_per_second:.1f} tok/s[/dim]")
    runner.unload()


@cli.command("reason")
@click.argument("question")
@click.argument("model_path")
@click.option("--max-iterations", "-i", default=5, help="Max reasoning steps")
@click.pass_context
def reason_cmd(ctx, question, model_path, max_iterations):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)
    runner.load()

    from localprompt.tools.reasoning import Reasoner
    reasoner = Reasoner()
    result = reasoner.reason(question, runner, max_iterations)
    console.print(Panel.fit(result, title="Reasoning Result"))
    runner.unload()


@cli.command("search")
@click.argument("query")
@click.option("--provider", "-p", default="duckduckgo", help="Search provider")
def search_cmd(query, provider):
    from localprompt.tools.web_search import web_search
    console.print(f"[bold]Searching for: {query}[/bold]")
    results = web_search(query, provider=provider)
    if not results:
        console.print("[dim]No results found.[/dim]")
        return
    table = Table(show_header=True)
    table.add_column("Title", style="green")
    table.add_column("URL", style="cyan")
    table.add_column("Snippet", style="dim")
    for r in results:
        table.add_row(r.get("title", ""), r.get("url", ""), r.get("snippet", "")[:100])
    console.print(table)


@cli.command("providers")
@click.option("--set", "set_provider", nargs=2, metavar="NAME KEY_OR_URL", help="Set provider config")
@click.option("--list", "list_providers", is_flag=True, help="List providers")
@click.pass_context
def providers_cmd(ctx, set_provider, list_providers):
    config = load_config()
    if set_provider:
        name, value = set_provider
        providers = config.get("providers", {})
        if name in ("ollama",):
            providers[name] = {"base_url": value}
        else:
            providers[name] = {"api_key": value}
        config["providers"] = providers
        save_config(config)
        console.print(f"[green]Set provider {name}[/green]")
        return
    if list_providers:
        from localprompt.providers import list_providers as _list
        table = Table(show_header=True)
        table.add_column("Provider", style="green")
        table.add_column("Available", style="yellow")
        for p in _list():
            table.add_row(p, "Configurable")
        console.print(table)
        return
    console.print(json.dumps(config.get("providers", {}), indent=2))


@cli.command("mcp")
@click.argument("action", required=False)
@click.argument("name", required=False)
@click.argument("command", required=False)
@click.option("--args", "-a", multiple=True, help="MCP server args")
@click.pass_context
def mcp_cmd(ctx, action, name, command, args):
    from localprompt.mcp import MCPManager
    mm = MCPManager()
    if action == "add":
        if not name or not command:
            console.print("[red]Usage: localprompt mcp add NAME --command CMD[/red]")
            return
        mm.add_server(name, command, list(args))
        console.print(f"[green]Added MCP server: {name}[/green]")
    elif action == "remove":
        mm.remove_server(name)
        console.print(f"[green]Removed MCP server: {name}[/green]")
    elif action == "list":
        servers = mm.list_servers()
        if not servers:
            console.print("[dim]No MCP servers configured.[/dim]")
        for s in servers:
            console.print(f"  [green]{s}[/green]")
    elif action == "tools":
        tools = mm.get_tools()
        for server, server_tools in tools.items():
            console.print(f"[bold]{server}[/bold]:")
            for t in server_tools:
                console.print(f"  - {t.get('name', 'unknown')}")
    elif action == "call":
        if not name or not command:
            console.print("[red]Usage: localprompt mcp call SERVER TOOL[/red]")
            return
        result = mm.call_tool(name, command)
        console.print(result)
    else:
        console.print("Usage: localprompt mcp [add|remove|list|tools|call] [NAME] [CMD]")


@cli.command("models")
@click.pass_context
def models_cmd(ctx):
    models = discover_models()
    if not models:
        console.print("[yellow]No models found.[/yellow]")
        return
    table = Table(show_header=True)
    table.add_column("#", style="dim", width=3)
    table.add_column("Name", style="green")
    table.add_column("Size", style="yellow")
    table.add_column("Path", style="dim")
    for i, m in enumerate(models, 1):
        table.add_row(str(i), m["name"], f"{m['size_gb']}GB", m["path"])
    console.print(table)


@cli.command("download")
@click.argument("model_id")
@click.option("--filename", "-f", default=None, help="GGUF filename")
@click.pass_context
def download_cmd(ctx, model_id, filename):
    from localprompt.download import download_model
    config = ctx.obj["config"]
    with console.status(f"[bold cyan]Resolving {model_id}[/bold cyan]"):
        path = download_model(model_id, filename=filename)
    console.print(f"[green]Saved: {path}[/green]")


@cli.command("memory")
@click.argument("action", required=False)
@click.argument("query", required=False)
@click.pass_context
def memory_cmd(ctx, action, query):
    config = ctx.obj["config"]
    from localprompt.memory import HiveMem, LocalMem, MemoryManager
    mm = MemoryManager(config)
    if action == "clear" or action == "reset":
        mm.hive = HiveMem(config.get("hive_mem_file"))
        console.print("[green]Memory cleared.[/green]")
    elif action == "view" or action is None:
        data = mm.hive.get_all()
        if not data:
            console.print("[dim]No memories.[/dim]")
        for k, v in data.items():
            console.print(f"[green]{k}[/green]: {str(v)[:100]}")
    elif action == "search" and query:
        results = mm.search_all(query)
        for r in results:
            if r["results"]:
                console.print(f"[cyan]{r['source']}[/cyan]:")
                for item in r["results"][:5]:
                    console.print(f"  {str(item.get('value', item))[:100]}")


@cli.command("hive")
@click.argument("action", required=False)
@click.pass_context
def hive_cmd(ctx, action):
    config = ctx.obj["config"]
    from localprompt.memory import HiveMem
    hive = HiveMem(config.get("hive_mem_file"))
    if action == "sync":
        hive.sync()
        console.print("[green]Hive synced.[/green]")
    elif action == "view" or action is None:
        data = hive.get_all()
        console.print(json.dumps(data, indent=2, default=str)[:2000])
    elif action == "clear":
        hive = HiveMem(config.get("hive_mem_file"))
        hive._data = {}
        hive.save()
        console.print("[green]Hive cleared.[/green]")


@cli.command("config")
@click.option("--set", "set_key", nargs=2, metavar="KEY VALUE", help="Set config")
@click.option("--get", "get_key", default=None, help="Get config")
@click.option("--list", "list_config", is_flag=True, help="List all")
@click.pass_context
def cfg(ctx, set_key, get_key, list_config):
    config = load_config()
    if set_key:
        key, value = set_key
        try:
            value = json.loads(value)
        except (json.JSONDecodeError, ValueError):
            pass
        config[key] = value
        save_config(config)
        console.print(f"[green]Set {key} = {value}[/green]")
        return
    if get_key:
        console.print(config.get(get_key))
        return
    if list_config:
        table = Table(show_header=True)
        table.add_column("Key", style="green")
        table.add_column("Value", style="yellow")
        for k, v in sorted(config.items()):
            table.add_row(k, str(v))
        console.print(table)
    else:
        console.print(json.dumps(config, indent=2))


@cli.command("info")
@click.argument("model_path")
@click.pass_context
def info_cmd(ctx, model_path):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)
    try:
        runner.load()
        info = runner.model_info
        console.print(Panel.fit(
            f"Name: {info.name}\nParameters: {info.param_count}\nContext: {info.context_size}\nEmbedding dim: {info.embedding_dim}",
            title="Model Info",
        ))
        runner.unload()
    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")


@cli.command("version")
def version_cmd():
    console.print(f"LocalPrompt v{__version__}")
    console.print(f"Python: {sys.version}")


def main():
    cli(obj={})


if __name__ == "__main__":
    main()

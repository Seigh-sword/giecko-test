import click
import json
import os
import sys
import time
from pathlib import Path

from rich.console import Console
from rich.markup import escape
from rich.table import Table
from rich.panel import Panel

from localchat import __version__
from localchat.config import (
    load_config,
    save_config,
    get_models_dir,
    discover_models,
    get_config_path,
)
from localchat.model import ModelRunner, GenerationResult
from localchat.chat import ChatSession
from localchat.download import (
    download_model,
    list_huggingface_models,
    resolve_gguf_url,
)
from localchat.templates import get_template, detect_template_from_prompt
from localchat.utils import console, format_file_size


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
@click.option("--interactive/--no-interactive", default=True, help="Interactive mode")
@click.option("--prompt", "-p", default=None, help="Single prompt to run and exit")
@click.option("--max-tokens", "-m", default=512, help="Max tokens to generate")
@click.option("--temperature", "-t", default=None, type=float, help="Temperature")
@click.option("--top-p", default=None, type=float, help="Top P")
@click.option("--save-conversation/--no-save", default=False, help="Save conversation")
@click.pass_context
def chat(ctx, model_path, system, interactive, prompt, max_tokens, temperature, top_p, save_conversation):
    config = ctx.obj["config"]

    if model_path is None:
        model_path = config.get("default_model")
    if model_path is None:
        models = discover_models()
        if models:
            model_path = models[0]["path"]
            console.print(f"[yellow]Using default model: {model_path}[/yellow]")
        else:
            console.print("[red]No model specified and no models found.[/red]")
            console.print("[yellow]Use: localchat download <model_id>[/yellow]")
            sys.exit(1)

    if prompt is not None:
        runner = ModelRunner(model_path, config)
        runner.load()
        template = get_template(model_path)
        formatted_prompt = format_chat(template, system, [], prompt)
        console.print(f"[bold blue]Assistant:[/bold blue] ", end="", flush=True)
        full_response = ""
        for chunk in runner.generate(formatted_prompt, max_tokens=max_tokens, temperature=temperature, top_p=top_p, stream=config.get("streaming", True)):
            console.print(chunk, end="", flush=True)
            full_response += chunk
        console.print()
        runner.unload()
        return

    session = ChatSession(model_path, system_message=system, config=config)
    session.start(save_conversation=save_conversation)


@cli.command("generate")
@click.argument("model_path")
@click.argument("prompt")
@click.option("--max-tokens", "-m", default=512, help="Max tokens to generate")
@click.option("--temperature", "-t", default=None, type=float, help="Temperature")
@click.option("--top-p", default=None, type=float, help="Top P")
@click.option("--top-k", default=None, type=int, help="Top K")
@click.option("--repeat-penalty", default=None, type=float, help="Repeat penalty")
@click.pass_context
def generate(ctx, model_path, prompt, max_tokens, temperature, top_p, top_k, repeat_penalty):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)
    runner.load()

    console.print(f"[bold]Model:[/bold] {model_path}")
    console.print(f"[bold]Prompt tokens:[/bold] {runner.count_tokens(prompt)}")
    console.print()

    result = runner.generate_full(
        prompt,
        max_tokens=max_tokens,
        temperature=temperature,
        top_p=top_p,
        repeat_penalty=repeat_penalty,
    )

    console.print("[bold blue]Response:[/bold blue]")
    console.print(result.text)
    console.print()
    console.print(f"[dim]Generated {result.tokens_predicted} tokens in {result.total_duration:.2f}s[/dim]")
    if result.tokens_per_second > 0:
        console.print(f"[dim]Speed: {result.tokens_per_second:.1f} tok/s[/dim]")

    runner.unload()


@cli.command("download")
@click.argument("model_id")
@click.option("--filename", "-f", default=None, help="Specific GGUF filename to download")
@click.option("--token", "-t", default=None, help="HuggingFace access token")
@click.option("--dir", default=None, help="Download directory")
@click.pass_context
def download(ctx, model_id, filename, token, dir):
    config = ctx.obj["config"]

    with console.status(f"[bold cyan]Resolving model {model_id}[/bold cyan]"):
        path = download_model(model_id, save_dir=dir, filename=filename, token=token)

    console.print(f"\n[green]Model ready at: {path}[/green]")
    console.print(f"Use it with: localchat chat {path}")


@cli.command("models")
@click.pass_context
def models(ctx):
    config = ctx.obj["config"]
    models = discover_models()

    if not models:
        console.print("[yellow]No models found in configured directory.[/yellow]")
        console.print(f"Models dir: {get_models_dir()}")
        console.print("[yellow]Use 'localchat download <model_id>' to download one.[/yellow]")
        return

    table = Table(show_header=True)
    table.add_column("#", style="dim", width=3)
    table.add_column("Name", style="green")
    table.add_column("Size", style="yellow")
    table.add_column("Path", style="dim")

    for i, m in enumerate(models, 1):
        table.add_row(str(i), m["name"], f"{m['size_gb']}GB", m["path"])

    console.print(table)


@cli.command("list-models")
def list_models():
    ctx.invoke(models)


@cli.command("info")
@click.argument("model_path")
@click.pass_context
def info(ctx, model_path):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)

    try:
        runner.load()
        info = runner.model_info
        console.print(Panel.fit(
            f"[bold]Name:[/bold] {info.name}\n"
            f"[bold]Parameters:[/bold] {info.param_count:,}\n"
            f"[bold]Context:[/bold] {info.context_size}\n"
            f"[bold]Embedding dim:[/bold] {info.embedding_dim}\n"
            f"[bold]Path:[/bold] {info.path}",
            title="Model Info",
        ))
        runner.unload()
    except Exception as e:
        console.print(f"[red]Error loading model: {e}[/red]")


@cli.command("template")
@click.argument("model_name", nargs=-1)
def show_template(model_name):
    name = " ".join(model_name) if model_name else "llama2"
    template = get_template(name)
    console.print(Panel.fit(
        escape(template),
        title=f"Chat Template: {name}",
    ))


@cli.command("download-models")
def download_models():
    list_huggingface_models()


@cli.command("config")
@click.option("--set", "set_key", nargs=2, metavar="KEY VALUE", help="Set a config value")
@click.option("--get", "get_key", default=None, help="Get a config value")
@click.option("--list/--no-list", "list_config", default=False, help="List all config values")
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
        value = config.get(get_key)
        console.print(f"{value}")
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


@cli.command("eval")
@click.argument("model_path")
@click.argument("prompt")
@click.option("--max-tokens", "-m", default=128, help="Max tokens")
@click.pass_context
def eval_cmd(ctx, model_path, prompt, max_tokens):
    config = ctx.obj["config"]
    runner = ModelRunner(model_path, config)
    runner.load()

    result = runner.generate_full(prompt, max_tokens=max_tokens)

    console.print(result.text)
    console.print()
    console.print(f"[dim]Tokens: {result.tokens_predicted} predicted, {result.tokens_evaluated} evaluated[/dim]")
    console.print(f"[dim]Time: {result.total_duration:.2f}s, {result.tokens_per_second:.1f} tok/s[/dim]")

    runner.unload()


@cli.command("version")
def version():
    console.print(f"LocalChat v{__version__}")
    console.print(f"Python: {sys.version}")


def main():
    cli(obj={})


if __name__ == "__main__":
    main()

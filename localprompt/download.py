import os
import requests
from pathlib import Path
from rich.table import Table

from localchat.config import get_models_dir
from localchat.utils import console, format_file_size


HF_BASE = "https://huggingface.co"

POPULAR_MODELS = [
    "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    "TheBloke/Llama-2-7B-Chat-GGUF",
    "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
    "TheBloke/Phi-2-GGUF",
    "TheBloke/Gemma-2-9B-It-GGUF",
    "TheBloke/Qwen2-7B-Chat-GGUF",
    "TheBloke/Meta-Llama-2-7B-Chat-GGUF",
    "bartowski/Llama-2-7B-Chat-GGUF",
    "barisian/Phi-3-mini-4k-GGUF",
    "UnfilteredAI/Meta-Llama-2-7B-Chat-GGUF",
]


def resolve_gguf_url(model_id: str, filename: str = None, token: str = None) -> str:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    if filename:
        return f"{HF_BASE}/{model_id}/resolve/main/{filename}"

    api_url = f"{HF_BASE}/api/models/{model_id}"
    resp = requests.get(api_url, headers=headers)
    resp.raise_for_status()
    data = resp.json()

    gguf_files = []
    for file_info in data.get("siblings", []):
        fname = file_info.get("rfilename", "")
        if fname.lower().endswith(".gguf"):
            gguf_files.append(fname)

    if not gguf_files:
        raise ValueError(f"No GGUF files found for {model_id}")

    preferred = None
    for f in gguf_files:
        fl = f.lower()
        if "q4" in fl and "k" in fl and "0" in fl:
            preferred = f
            break
        if "q4" in fl and "0" in fl:
            preferred = f
            break
    if preferred is None:
        preferred = gguf_files[0]

    return f"{HF_BASE}/{model_id}/resolve/main/{preferred}"


def download_model(model_id: str, save_dir: str = None, filename: str = None, token: str = None, progress=None):
    if save_dir is None:
        save_dir = str(get_models_dir())

    os.makedirs(save_dir, exist_ok=True)

    url = resolve_gguf_url(model_id, filename, token)

    path_part = url.replace(HF_BASE + "/", "").replace("/", "__")
    save_path = Path(save_dir) / path_part

    if save_path.exists():
        console.print(f"[green]Model already exists at {save_path}[/green]")
        return str(save_path)

    console.print(f"[bold]Downloading[/bold]: {model_id}")
    console.print(f"[dim]URL: {url}[/dim]")
    console.print(f"[dim]Saving to: {save_path}[/dim]")

    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    resp = requests.get(url, headers=headers, stream=True)
    resp.raise_for_status()

    total_size = int(resp.headers.get("content-length", 0))

    if progress is not None:
        progress_task = progress.add_task(
            f"[cyan]{model_id}[/cyan]",
            total=total_size,
            unit="B",
            unit_scale=True,
        )
    else:
        progress_task = None

    downloaded = 0
    with open(save_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
                downloaded += len(chunk)
                if progress_task:
                    progress.update(progress_task, advance=len(chunk))

    console.print(f"[green]Download complete:[/green] {save_path} ({format_file_size(save_path.stat().st_size)})")
    return str(save_path)


def list_huggingface_models():
    console.print("[bold]Popular models available on HuggingFace:[/bold]\n")
    table = Table(show_header=True)
    table.add_column("Model", style="green")
    table.add_column("Description", style="dim")
    table.add_column("Has GGUF", style="yellow")

    for model_id in POPULAR_MODELS:
        try:
            api_url = f"{HF_BASE}/api/models/{model_id}"
            resp = requests.get(api_url, timeout=10)
            if resp.status_code == 200:
                data = resp.json()
                tags = data.get("tags", [])
                description = data.get("description", "")
                siblings = data.get("siblings", [])
                has_gguf = any(s.get("rfilename", "").lower().endswith(".gguf") for s in siblings)

                desc_short = (description[:60] + "...") if len(description) > 60 else description
                arch = next((t for t in tags if t.startswith("architecture:")), "")
                if arch:
                    desc_short = f"{arch.replace('architecture:', '')}: {desc_short}"

                table.add_row(model_id, desc_short, "Yes" if has_gguf else "No")
            else:
                table.add_row(model_id, "Unavailable", "?")
        except Exception:
            table.add_row(model_id, "Error checking", "?")

    console.print(table)

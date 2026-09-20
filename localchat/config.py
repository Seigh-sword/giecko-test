import json
import os
from pathlib import Path

DEFAULT_CONFIG = {
    "models_dir": str(Path.home() / ".localchat" / "models"),
    "temperature": 0.7,
    "top_p": 0.9,
    "top_k": 40,
    "repeat_penalty": 1.1,
    "context_size": 4096,
    "n_gpu_layers": 0,
    "n_ctx": 4096,
    "streaming": True,
    "history_file": str(Path.home() / ".localchat" / "conversations.json"),
    "default_model": None,
}


def get_config_path():
    return Path.home() / ".localchat" / "config.json"


def load_config():
    config_path = get_config_path()
    config = dict(DEFAULT_CONFIG)
    if config_path.exists():
        with open(config_path, "r") as f:
            user_config = json.load(f)
            config.update(user_config)
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    return config


def save_config(config):
    config_path = get_config_path()
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)


def get_models_dir(config=None):
    if config is None:
        config = load_config()
    return Path(config["models_dir"])


def discover_models(models_dir=None):
    if models_dir is None:
        models_dir = get_models_dir()
    models = []
    if not models_dir.exists():
        return models
    for path in sorted(models_dir.rglob("*.gguf")):
        models.append({
            "name": path.stem,
            "path": str(path),
            "size_gb": round(path.stat().st_size / (1024**3), 2),
        })
    return models

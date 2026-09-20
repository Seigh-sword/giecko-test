"""LocalPrompt utilities."""

import time
import sys
from rich.console import Console
from rich.text import Text

console = Console()


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.1f}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def format_tokens_per_sec(tps: float) -> str:
    return f"{tps:.1f} tok/s"


def format_file_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes}B"
    if size_bytes < 1024**2:
        return f"{size_bytes / 1024:.1f}KB"
    if size_bytes < 1024**3:
        return f"{size_bytes / (1024**2):.1f}MB"
    return f"{size_bytes / (1024**3):.2f}GB"


def print_streaming(text: str, delay: float = 0.01):
    for char in text:
        sys.stdout.write(char)
        sys.stdout.flush()
        if delay > 0:
            time.sleep(delay)
    print()


def truncate(text: str, max_len: int = 200) -> str:
    if len(text) > max_len:
        return text[:max_len] + "..."
    return text


def format_number(n: int) -> str:
    if n >= 1e9:
        return f"{n / 1e9:.1f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)

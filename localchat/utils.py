import time
import sys
from rich.console import Console

console = Console()


def format_duration(seconds):
    if seconds < 60:
        return f"{seconds:.1f}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def format_tokens_per_sec(tokens_per_second):
    return f"{tokens_per_second:.1f} tok/s"


def format_number(n):
    if n >= 1e9:
        return f"{n / 1e9:.1f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


def print_streaming(text, delay=0.01):
    for char in text:
        sys.stdout.write(char)
        sys.stdout.flush()
        if delay > 0:
            time.sleep(delay)
    print()


def format_file_size(size_bytes):
    if size_bytes < 1024:
        return f"{size_bytes}B"
    if size_bytes < 1024**2:
        return f"{size_bytes / 1024:.1f}KB"
    if size_bytes < 1024**3:
        return f"{size_bytes / (1024**2):.1f}MB"
    return f"{size_bytes / (1024**3):.2f}GB"

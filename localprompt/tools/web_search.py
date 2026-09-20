import requests
from typing import Dict, List, Optional

from localprompt.utils import console


def duckduckgo_search(query: str, max_results: int = 5) -> List[Dict[str, str]]:
    """Search via DuckDuckGo HTML (no API key needed)."""
    headers = {"User-Agent": "LocalPrompt/1.0"}
    url = f"https://html.duckduckgo.com/html/?q={requests.utils.quote(query)}"
    try:
        resp = requests.get(url, headers=headers, timeout=15)
        resp.raise_for_status()
        results = []
        import re
        for match in re.finditer(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', resp.text):
            url = match.group(1)
            title = re.sub(r'<[^>]+>', '', match.group(2))
            snippet_match = re.search(r'class="result__snippet"[^>]*>(.*?)</[at]', resp.text[match.end():])
            snippet = re.sub(r'<[^>]+>', '', snippet_match.group(1)) if snippet_match else ""
            results.append({"title": title, "url": url, "snippet": snippet})
            if len(results) >= max_results:
                break
        return results
    except Exception as e:
        console.print(f"[red]Search error: {e}[/red]")
        return []


def google_search(query: str, api_key: Optional[str] = None, max_results: int = 5) -> List[Dict[str, str]]:
    """Search via Google Custom Search API (requires API key)."""
    if not api_key:
        return duckduckgo_search(query, max_results)
    import json
    cx = os.environ.get("GOOGLE_CX", "")
    url = f"https://www.googleapis.com/customsearch/v1?q={requests.utils.quote(query)}&key={api_key}&cx={cx}"
    try:
        resp = requests.get(url, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        results = []
        for item in data.get("items", [])[:max_results]:
            results.append({
                "title": item.get("title", ""),
                "url": item.get("link", ""),
                "snippet": item.get("snippet", ""),
            })
        return results
    except Exception as e:
        console.print(f"[red]Search error: {e}[/red]")
        return []


import os


def web_search(query: str, provider: str = "duckduckgo", **kwargs) -> List[Dict[str, str]]:
    """Universal web search."""
    if provider == "duckduckgo":
        return duckduckgo_search(query, kwargs.get("max_results", 5))
    elif provider == "google":
        return google_search(query, kwargs.get("api_key"), kwargs.get("max_results", 5))
    return duckduckgo_search(query, kwargs.get("max_results", 5))

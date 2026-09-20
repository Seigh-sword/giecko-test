import os
import json
from typing import Optional, Dict, Any, List
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from rich.console import Console

from localprompt.utils import console


@dataclass
class ProviderConfig:
    name: str
    api_key: Optional[str] = None
    base_url: Optional[str] = None
    model: Optional[str] = None
    extra: Dict[str, Any] = field(default_factory=dict)


class BaseProvider(ABC):
    """Abstract base class for AI providers."""

    def __init__(self, config: ProviderConfig):
        self.config = config

    @abstractmethod
    def complete(self, prompt: str, **kwargs) -> str:
        pass

    @abstractmethod
    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        pass

    @abstractmethod
    def is_available(self) -> bool:
        pass

    @property
    @abstractmethod
    def provider_name(self) -> str:
        pass


class OllamaProvider(BaseProvider):
    """Ollama provider for local models via API."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self.base_url = config.base_url or "http://localhost:11434"

    @property
    def provider_name(self) -> str:
        return "ollama"

    def is_available(self) -> bool:
        try:
            import requests
            r = requests.get(f"{self.base_url}/api/tags", timeout=5)
            return r.status_code == 200
        except Exception:
            return False

    def complete(self, prompt: str, **kwargs) -> str:
        import requests
        max_tokens = kwargs.get("max_tokens", 512)
        temperature = kwargs.get("temperature", 0.7)
        response = requests.post(
            f"{self.base_url}/api/generate",
            json={"model": self.config.model or "llama3", "prompt": prompt, "stream": False, "options": {"temperature": temperature, "num_predict": max_tokens}},
            timeout=120,
        )
        response.raise_for_status()
        return response.json().get("response", "")

    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        import requests
        max_tokens = kwargs.get("max_tokens", 512)
        temperature = kwargs.get("temperature", 0.7)
        response = requests.post(
            f"{self.base_url}/api/chat",
            json={"model": self.config.model or "llama3", "messages": messages, "stream": False, "options": {"temperature": temperature, "num_predict": max_tokens}},
            timeout=120,
        )
        response.raise_for_status()
        return response.json().get("message", {}).get("content", "")


class OpenAIProvider(BaseProvider):
    """OpenAI-compatible provider."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self.base_url = config.base_url or "https://api.openai.com/v1"

    @property
    def provider_name(self) -> str:
        return "openai"

    def is_available(self) -> bool:
        return bool(self.config.api_key)

    def _headers(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self.config.api_key}", "Content-Type": "application/json"}

    def complete(self, prompt: str, **kwargs) -> str:
        import requests
        response = requests.post(
            f"{self.base_url}/completions",
            headers=self._headers(),
            json={"model": self.config.model or "gpt-3.5-turbo-instruct", "prompt": prompt, "max_tokens": kwargs.get("max_tokens", 512), "temperature": kwargs.get("temperature", 0.7)},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["text"]

    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        import requests
        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers=self._headers(),
            json={"model": self.config.model or "gpt-3.5-turbo", "messages": messages, "max_tokens": kwargs.get("max_tokens", 512), "temperature": kwargs.get("temperature", 0.7)},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"]


class AnthropicProvider(BaseProvider):
    """Anthropic Claude provider."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self.base_url = config.base_url or "https://api.anthropic.com/v1"

    @property
    def provider_name(self) -> str:
        return "anthropic"

    def is_available(self) -> bool:
        return bool(self.config.api_key)

    def _headers(self) -> Dict[str, str]:
        return {"x-api-key": self.config.api_key or "", "Content-Type": "application/json", "anthropic-version": "2023-06-01"}

    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        import requests
        max_tokens = kwargs.get("max_tokens", 1024)
        response = requests.post(
            f"{self.base_url}/messages",
            headers=self._headers(),
            json={"model": self.config.model or "claude-3-haiku-20240307", "max_tokens": max_tokens, "temperature": kwargs.get("temperature", 0.7), "messages": messages},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["content"][0]["text"] if response.json().get("content") else ""


class GoogleProvider(BaseProvider):
    """Google Gemini provider."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self.base_url = config.base_url or "https://generativelanguage.googleapis.com/v1beta"

    @property
    def provider_name(self) -> str:
        return "google"

    def is_available(self) -> bool:
        return bool(self.config.api_key)

    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        import requests
        max_tokens = kwargs.get("max_tokens", 1024)
        contents = [{"role": m["role"], "parts": [{"text": m["content"]}]} for m in messages]
        response = requests.post(
            f"{self.base_url}/models/{self.config.model or 'gemini-1.5-flash'}:generateContent?key={self.config.api_key}",
            json={"contents": contents, "generationConfig": {"maxOutputTokens": max_tokens, "temperature": kwargs.get("temperature", 0.7)}},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["candidates"][0]["content"]["parts"][0]["text"]


class HuggingFaceProvider(BaseProvider):
    """HuggingFace Inference API provider."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self.base_url = "https://api-inference.huggingface.co"

    @property
    def provider_name(self) -> str:
        return "huggingface"

    def is_available(self) -> bool:
        return bool(self.config.api_key)

    def complete(self, prompt: str, **kwargs) -> str:
        import requests
        headers = {"Authorization": f"Bearer {self.config.api_key}"}
        response = requests.post(
            f"{self.base_url}/models/{self.config.model or 'mistralai/Mistral-7B-Instruct-v0.3'}",
            headers=headers,
            json={"inputs": prompt, "parameters": {"max_new_tokens": kwargs.get("max_tokens", 512), "temperature": kwargs.get("temperature", 0.7)}},
            timeout=120,
        )
        response.raise_for_status()
        return response.json().get("generated_text", "")

    def chat(self, messages: List[Dict[str, str]], **kwargs) -> str:
        return self.complete("\n".join(f"{m['role']}: {m['content']}" for m in messages), **kwargs)


PROVIDER_REGISTRY = {
    "ollama": OllamaProvider,
    "openai": OpenAIProvider,
    "anthropic": AnthropicProvider,
    "google": GoogleProvider,
    "huggingface": HuggingFaceProvider,
}


def get_provider(name: str, config: ProviderConfig) -> BaseProvider:
    cls = PROVIDER_REGISTRY.get(name.lower())
    if cls is None:
        raise ValueError(f"Unknown provider: {name}")
    return cls(config)


def list_providers() -> List[str]:
    return list(PROVIDER_REGISTRY.keys())

import time
import logging
from pathlib import Path
from typing import Optional, List, Iterator
from dataclasses import dataclass, field

from llama_cpp import Llama

from localchat.config import load_config
from localchat.utils import format_tokens_per_sec, format_duration

logger = logging.getLogger(__name__)


@dataclass
class GenerationResult:
    text: str
    tokens_predicted: int
    tokens_evaluated: int
    total_duration: float
    stop_reason: Optional[str] = None

    @property
    def tokens_per_second(self):
        if self.total_duration > 0:
            return self.tokens_predicted / self.total_duration
        return 0.0


@dataclass
class ModelInfo:
    name: str
    path: str
    param_count: int = 0
    context_size: int = 0
    embedding_dim: int = 0
    tokenizer: Optional[str] = None


class ModelRunner:
    def __init__(self, model_path: str, config: Optional[dict] = None):
        self.model_path = model_path
        self.config = config or load_config()
        self.llm: Optional[Llama] = None
        self.model_info: Optional[ModelInfo] = None
        self._load_time: Optional[float] = None

    def load(self):
        logger.info(f"Loading model from {self.model_path}")
        start = time.time()
        n_ctx = self.config.get("n_ctx", 4096)
        n_gpu_layers = self.config.get("n_gpu_layers", 0)
        temp = self.config.get("temperature", 0.7)
        top_p = self.config.get("top_p", 0.9)
        top_k = self.config.get("top_k", 40)
        repeat_penalty = self.config.get("repeat_penalty", 1.1)

        self.llm = Llama(
            model_path=self.model_path,
            n_ctx=n_ctx,
            n_gpu_layers=n_gpu_layers,
            verbose=False,
        )
        self._load_time = time.time() - start

        try:
            meta = getattr(self.llm, "metadata", {}) or {}
            arch = meta.get("general.architecture", "unknown")
            model_name = meta.get("general.name", Path(self.model_path).stem)
            context_length = int(meta.get("llama.context_length", self.llm.n_ctx()))
            embedding_dim = self.llm.n_embd()
            vocab_size = self.llm.n_vocab()
            n_layers = int(meta.get("llama.block_count", 0))
            n_heads = int(meta.get("llama.attention.head_count", 0))
            ffn_dim = int(meta.get("llama.feed_forward_length", embedding_dim * 2))

            # Rough parameter count estimation
            param_count = 0
            param_count += vocab_size * embedding_dim  # token embedding
            param_count += n_layers * (embedding_dim * 4 * ffn_dim + embedding_dim * embedding_dim * 2)  # transformer layers
            param_count += vocab_size * embedding_dim  # output projection
            param_count = int(param_count * 1e-6)  # in millions

            self.model_info = ModelInfo(
                name=model_name,
                path=self.model_path,
                param_count=param_count,
                context_size=context_length,
                embedding_dim=embedding_dim,
                tokenizer=f"vocab={vocab_size}",
            )
        except Exception:
            self.model_info = ModelInfo(
                name=Path(self.model_path).stem,
                path=self.model_path,
            )

        logger.info(f"Model loaded in {self._load_time:.1f}s")
        return self

    def tokenize(self, text: str) -> List[int]:
        if self.llm is None:
            raise RuntimeError("Model not loaded")
        return self.llm.tokenize(text.encode("utf-8"))

    def detokenize(self, tokens: List[int]) -> str:
        if self.llm is None:
            raise RuntimeError("Model not loaded")
        return self.llm.detokenize(tokens).decode("utf-8", errors="replace")

    def generate(
        self,
        prompt: str,
        max_tokens: int = 512,
        temperature: Optional[float] = None,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
        repeat_penalty: Optional[float] = None,
        stream: bool = True,
    ) -> Iterator[str]:
        if self.llm is None:
            raise RuntimeError("Model not loaded")

        temp = temperature if temperature is not None else self.config.get("temperature", 0.7)
        p = top_p if top_p is not None else self.config.get("top_p", 0.9)
        k = top_k if top_k is not None else self.config.get("top_k", 40)
        rp = repeat_penalty if repeat_penalty is not None else self.config.get("repeat_penalty", 1.1)

        completion = self.llm.create_completion(
            prompt,
            max_tokens=max_tokens,
            temperature=temp,
            top_p=p,
            top_k=k,
            repeat_penalty=rp,
            stream=stream,
        )

        if stream:
            for chunk in completion:
                if "choices" in chunk and len(chunk["choices"]) > 0:
                    text = chunk["choices"][0].get("text", "")
                    if text:
                        yield text
        else:
            if "choices" in completion and len(completion["choices"]) > 0:
                yield completion["choices"][0].get("text", "")

    def generate_full(
        self,
        prompt: str,
        max_tokens: int = 512,
        temperature: Optional[float] = None,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
        repeat_penalty: Optional[float] = None,
    ) -> GenerationResult:
        if self.llm is None:
            raise RuntimeError("Model not loaded")

        temp = temperature if temperature is not None else self.config.get("temperature", 0.7)
        p = top_p if top_p is not None else self.config.get("top_p", 0.9)
        k = top_k if top_k is not None else self.config.get("top_k", 40)
        rp = repeat_penalty if repeat_penalty is not None else self.config.get("repeat_penalty", 1.1)

        start = time.time()
        result = self.llm.create_completion(
            prompt,
            max_tokens=max_tokens,
            temperature=temp,
            top_p=p,
            top_k=k,
            repeat_penalty=rp,
            stream=False,
        )
        duration = time.time() - start

        text = ""
        tokens_predicted = 0
        tokens_evaluated = 0
        stop_reason = None

        if "choices" in result and len(result["choices"]) > 0:
            choice = result["choices"][0]
            text = choice.get("text", "")
            stop_reason = choice.get("finish_reason")

        if "usage" in result:
            tokens_evaluated = result["usage"].get("prompt_tokens", 0)
            tokens_predicted = result["usage"].get("completion_tokens", 0)

        return GenerationResult(
            text=text,
            tokens_predicted=tokens_predicted,
            tokens_evaluated=tokens_evaluated,
            total_duration=duration,
            stop_reason=stop_reason,
        )

    def count_tokens(self, prompt: str) -> int:
        tokens = self.tokenize(prompt)
        return len(tokens)

    def unload(self):
        if self.llm is not None:
            del self.llm
            self.llm = None
            self.model_info = None

    def __del__(self):
        self.unload()

    def __repr__(self):
        if self.model_info:
            return f"ModelRunner(name={self.model_info.name}, params={self.model_info.param_count}, ctx={self.model_info.context_size})"
        return "ModelRunner(unloaded)"

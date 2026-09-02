"""Answer generators under test, behind one protocol.

The point of the protocol is that the generation eval scores a *pipeline*,
not a model: swap the generator and every safety check, grounding score and
slice breakdown still applies. That is what makes a model bake-off possible.

``gemma-2b`` is the model the app actually ships and is therefore the number
that matters, but its repository is gated -- it needs a Hugging Face token
with the licence accepted. The open models are stand-ins for developing the
harness and for comparing candidates.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any, Protocol

DEFAULT_MAX_NEW_TOKENS = 320


@dataclass(frozen=True, slots=True)
class GeneratorSpec:
    """A registered candidate generator.

    Attributes:
        key: Short name used in configs and reports.
        repo_id: Hugging Face repository.
        params_b: Approximate parameter count in billions.
        gated: True when the repo needs an accepted licence and a token.
        shipped: True for the model the app actually runs on-device.
    """

    key: str
    repo_id: str
    params_b: float
    gated: bool = False
    shipped: bool = False


def _spec(key: str, repo_id: str, params_b: float, **kw: Any) -> GeneratorSpec:
    """Shorthand for the registry below."""
    return GeneratorSpec(key=key, repo_id=repo_id, params_b=params_b, **kw)


GENERATORS: dict[str, GeneratorSpec] = {
    "gemma-2b": _spec("gemma-2b", "google/gemma-2-2b-it", 2.6, gated=True, shipped=True),
    "qwen-0.5b": _spec("qwen-0.5b", "Qwen/Qwen2.5-0.5B-Instruct", 0.5),
    "qwen-1.5b": _spec("qwen-1.5b", "Qwen/Qwen2.5-1.5B-Instruct", 1.5),
    "qwen-3b": _spec("qwen-3b", "Qwen/Qwen2.5-3B-Instruct", 3.1),
    "smollm-1.7b": _spec("smollm-1.7b", "HuggingFaceTB/SmolLM2-1.7B-Instruct", 1.7),
}


class Generator(Protocol):
    """Turns a built prompt into an answer."""

    name: str

    def generate(self, prompt: str) -> str:
        """Return the model's answer to ``prompt``."""
        ...

    def stream(self, prompt: str) -> Iterator[str]:
        """Yield the answer in pieces; optional, enables TTFT measurement."""
        ...


@dataclass(slots=True)
class ScriptedGenerator:
    """Returns canned answers -- lets the checks be tested without a model.

    Attributes:
        answers: ``query substring -> answer``. The first substring found in
            the prompt wins; ``default`` is used when none match.
    """

    answers: dict[str, str] = field(default_factory=dict)
    default: str = ""
    name: str = "scripted"

    def generate(self, prompt: str) -> str:
        """Return the first canned answer whose key appears in ``prompt``."""
        for needle, answer in self.answers.items():
            if needle.lower() in prompt.lower():
                return answer
        return self.default


@dataclass(slots=True)
class HuggingFaceGenerator:
    """transformers backend, used in the lab.

    The app runs MediaPipe/flutter_gemma on-device, not transformers, so this
    measures the *model's* behaviour rather than the runtime's. Prompt-level
    parity is handled by :mod:`survive_rag.generation.prompt`.
    """

    spec: GeneratorSpec
    max_new_tokens: int = DEFAULT_MAX_NEW_TOKENS
    temperature: float = 0.7
    top_k: int = 40
    device: str | None = None
    name: str = ""
    _pipe: Any = None

    def __post_init__(self) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.name = self.name or self.spec.key
        device = self.device or ("mps" if torch.backends.mps.is_available() else "cpu")
        # float16 on the GPU, float32 on CPU: fp16 halves the weights (a 1.5B
        # model is 6 GB at fp32, which thrashes on a laptop) but CPU kernels
        # for fp16 are slower than fp32, so the choice follows the device.
        dtype = torch.float16 if device == "mps" else torch.float32
        tokenizer = AutoTokenizer.from_pretrained(self.spec.repo_id)
        model = AutoModelForCausalLM.from_pretrained(
            self.spec.repo_id, dtype=dtype
        ).to(device)
        model.eval()
        self._pipe = (tokenizer, model, device)

    def _encode(self, prompt: str) -> Any:
        """Apply the model's chat template and move the tensors to its device."""
        tokenizer, _, device = self._pipe
        text = tokenizer.apply_chat_template(
            [{"role": "user", "content": prompt}],
            tokenize=False,
            add_generation_prompt=True,
        )
        return tokenizer(text, return_tensors="pt").to(device)

    def _kwargs(self) -> dict[str, Any]:
        """Sampling settings, mirroring the app's temp=0.7 / top_k=40."""
        tokenizer = self._pipe[0]
        return {
            "max_new_tokens": self.max_new_tokens,
            "do_sample": self.temperature > 0,
            "temperature": self.temperature,
            "top_k": self.top_k,
            "pad_token_id": tokenizer.eos_token_id,
        }

    def generate(self, prompt: str) -> str:
        """Generate one answer with the app's sampling settings."""
        import torch

        tokenizer, model = self._pipe[0], self._pipe[1]
        inputs = self._encode(prompt)
        with torch.no_grad():
            out = model.generate(**inputs, **self._kwargs())
        return tokenizer.decode(
            out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True
        ).strip()

    def stream(self, prompt: str) -> Iterator[str]:
        """Yield the answer in pieces, so time-to-first-token is measurable.

        Generation runs on a worker thread because ``model.generate`` blocks
        until it is finished; the streamer is the only way to observe when the
        first token actually appeared rather than inferring it afterwards.
        """
        from threading import Thread

        from transformers import TextIteratorStreamer

        tokenizer, model = self._pipe[0], self._pipe[1]
        inputs = self._encode(prompt)
        streamer = TextIteratorStreamer(
            tokenizer, skip_prompt=True, skip_special_tokens=True
        )
        thread = Thread(
            target=model.generate, kwargs={**inputs, **self._kwargs(), "streamer": streamer}
        )
        thread.start()
        try:
            yield from streamer
        finally:
            thread.join()


def load_generator(key: str, **kwargs: Any) -> Generator:
    """Build a generator for a registered key.

    Args:
        key: A key of :data:`GENERATORS`.
        **kwargs: Passed through to :class:`HuggingFaceGenerator`.

    Returns:
        A ready :class:`Generator`.

    Raises:
        KeyError: If ``key`` is not registered.
    """
    return HuggingFaceGenerator(spec=GENERATORS[key], **kwargs)

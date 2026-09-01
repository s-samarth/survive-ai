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


GENERATORS: dict[str, GeneratorSpec] = {
    "gemma-2b": GeneratorSpec(
        key="gemma-2b", repo_id="google/gemma-2-2b-it", params_b=2.6,
        gated=True, shipped=True,
    ),
    "qwen-0.5b": GeneratorSpec(
        key="qwen-0.5b", repo_id="Qwen/Qwen2.5-0.5B-Instruct", params_b=0.5
    ),
    "qwen-1.5b": GeneratorSpec(
        key="qwen-1.5b", repo_id="Qwen/Qwen2.5-1.5B-Instruct", params_b=1.5
    ),
    "qwen-3b": GeneratorSpec(
        key="qwen-3b", repo_id="Qwen/Qwen2.5-3B-Instruct", params_b=3.1
    ),
    "smollm-1.7b": GeneratorSpec(
        key="smollm-1.7b", repo_id="HuggingFaceTB/SmolLM2-1.7B-Instruct", params_b=1.7
    ),
}


class Generator(Protocol):
    """Turns a built prompt into an answer."""

    name: str

    def generate(self, prompt: str) -> str:
        """Return the model's answer to ``prompt``."""
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
        tokenizer = AutoTokenizer.from_pretrained(self.spec.repo_id)
        model = AutoModelForCausalLM.from_pretrained(
            self.spec.repo_id, dtype=torch.float32
        ).to(device)
        model.eval()
        self._pipe = (tokenizer, model, device)

    def generate(self, prompt: str) -> str:
        """Generate one answer with the app's sampling settings."""
        import torch

        tokenizer, model, device = self._pipe
        chat = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(
            chat, tokenize=False, add_generation_prompt=True
        )
        inputs = tokenizer(text, return_tensors="pt").to(device)
        with torch.no_grad():
            out = model.generate(
                **inputs,
                max_new_tokens=self.max_new_tokens,
                do_sample=self.temperature > 0,
                temperature=self.temperature,
                top_k=self.top_k,
                pad_token_id=tokenizer.eos_token_id,
            )
        return tokenizer.decode(
            out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True
        ).strip()


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

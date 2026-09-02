"""The embedding models this project knows how to use.

Separated from the backends that run them because the two change for different
reasons: a new model is a research decision, a new backend is an engineering
one. Keeping the registry here also lets tooling read the specs without pulling
in torch or onnxruntime.

Prefixes are not cosmetic. E5 and BGE are trained with asymmetric
``query:``/``passage:`` markers and lose real accuracy without them, so each
model carries its own rather than callers remembering.
"""

from __future__ import annotations

from dataclasses import dataclass

TORCH, ONNX = "torch", "onnx"


@dataclass(frozen=True, slots=True)
class ModelSpec:
    """Everything needed to use one embedding model correctly.

    Attributes:
        key: Short name used in configs and reports.
        repo_id: Hugging Face repository.
        dim: Native embedding width.
        params_m: Approximate parameter count in millions, for the size table.
        query_prefix: Text prepended to queries, if the model expects one.
        doc_prefix: Text prepended to documents, if the model expects one.
        matryoshka: True when the vector may be truncated without retraining.
        multilingual: True when the model was trained beyond English.
        pooling: How token vectors become a sentence vector. E5 and MiniLM
            mean-pool; BGE reads the CLS token. Getting this wrong silently
            produces plausible but much worse vectors.
        onnx_file: Path of the exported graph inside the ONNX repository.
        onnx_repo: Repository holding the ONNX export, when it is not
            ``repo_id``. Google publishes the EmbeddingGemma weights and the
            community publishes its quantised exports, so the two differ.
        onnx_output: Graph output to read. A graph that bakes pooling and the
            projection head in exposes a sentence-level output; reading
            ``last_hidden_state`` and pooling it by hand would silently skip
            that head and produce vectors from a different space.
    """

    key: str
    repo_id: str
    dim: int
    params_m: int
    query_prefix: str = ""
    doc_prefix: str = ""
    matryoshka: bool = False
    multilingual: bool = False
    pooling: str = "mean"
    onnx_file: str = "onnx/model.onnx"
    onnx_repo: str = ""
    onnx_output: str = ""


MODELS: dict[str, ModelSpec] = {
    "minilm": ModelSpec(
        key="minilm",
        repo_id="sentence-transformers/all-MiniLM-L6-v2",
        dim=384,
        params_m=22,
    ),
    "bge-small": ModelSpec(
        key="bge-small",
        repo_id="BAAI/bge-small-en-v1.5",
        dim=384,
        params_m=33,
        query_prefix="Represent this sentence for searching relevant passages: ",
        pooling="cls",
    ),
    "e5-small": ModelSpec(
        key="e5-small",
        repo_id="intfloat/multilingual-e5-small",
        dim=384,
        params_m=118,
        query_prefix="query: ",
        doc_prefix="passage: ",
        multilingual=True,
    ),
    "e5-base": ModelSpec(
        key="e5-base",
        repo_id="intfloat/multilingual-e5-base",
        dim=768,
        params_m=278,
        query_prefix="query: ",
        doc_prefix="passage: ",
        multilingual=True,
    ),
    "embeddinggemma": ModelSpec(
        key="embeddinggemma",
        repo_id="google/embeddinggemma-300m",
        dim=768,
        params_m=308,
        query_prefix="task: search result | query: ",
        doc_prefix="title: none | text: ",
        matryoshka=True,
        multilingual=True,
        # Google ships no ONNX export; the community one is what a phone can
        # actually load. q4f16 is 175 MB against 1.2 GB for the float graph.
        onnx_repo="onnx-community/embeddinggemma-300m-ONNX",
        onnx_file="onnx/model_q4f16.onnx",
        onnx_output="sentence_embedding",
    ),
}

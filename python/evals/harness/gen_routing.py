"""Glue between the router and the generation harness.

Kept apart from the runner because it answers a different question: not "what
did the model produce" but "should a model have been asked at all".
"""

from __future__ import annotations

from survive_rag.responses import capability_answer, decline_answer
from survive_rag.retrieval.expansion import is_transliterated
from survive_rag.retrieval.pipeline import Retriever
from survive_rag.routing import CAPABILITY, Route, Signals, route


def route_query(query: str, retriever: Retriever) -> Route:
    """Route one query using the retriever's own confidence signals."""
    return route(
        query,
        Signals(
            confidence=retriever.confidence(query),
            has_bridge_terms=is_transliterated(query),
        ),
    )


def canned_answer(intent: str) -> str:
    """The fixed text for a query answered without a model."""
    return capability_answer() if intent == CAPABILITY else decline_answer()

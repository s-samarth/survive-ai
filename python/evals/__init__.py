"""The Survive AI evaluation lab.

Deliberately **outside** ``survive_rag``. The package next door is the
reference implementation of what the app ships -- chunking, retrieval, the
prompt -- and it must stay small and dependency-light. This tree is the
apparatus we use to decide *whether* that implementation is good enough, and
none of it ever reaches a phone: golden sets, metrics, model backends,
reports, and the harnesses that drive them.

The dependency runs one way only: ``evals`` imports ``survive_rag``, never the
reverse. ``tests/test_architecture.py`` enforces it.
"""

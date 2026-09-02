"""Prompt construction -- the shippable half of generation.

The model backends that run these prompts live in ``evals/generators``:
they exist to compare candidates, and the app runs MediaPipe rather than
PyTorch, so they are lab apparatus and never ship.
"""

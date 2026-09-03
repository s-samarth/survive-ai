"""The lab must never become part of what ships.

``survive_rag`` is the reference implementation of the runtime: chunking,
retrieval, the prompt. ``evals`` is apparatus for deciding whether that
implementation is good enough. The dependency runs one way, and it is worth
enforcing mechanically rather than by discipline, because the failure is
silent -- an import added in a hurry does not break anything until someone
tries to ship, or until the "zero third-party dependencies" claim quietly
stops being true.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

LIBRARY = "survive_rag"
LAB = "evals"
# Modules the library may import only lazily, inside a function, because they
# pull in a third-party dependency the lexical path does not need.
LAZY_ONLY = {"numpy", "onnxruntime", "tokenizers", "sentence_transformers", "torch"}


def _python_files(package: str) -> list[Path]:
    """Every source file in a package, excluding caches."""
    root = Path(__file__).resolve().parents[1] / package
    return [p for p in root.rglob("*.py") if "__pycache__" not in p.parts]


def _imports(path: Path) -> list[tuple[str, int]]:
    """Every imported module name in ``path``, with its indentation column."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: list[tuple[str, int]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found += [(a.name, node.col_offset) for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            found.append((node.module, node.col_offset))
    return found


def test_library_never_imports_the_lab() -> None:
    """A shipped module importing the harness would drag the lab into the app."""
    offenders = [
        f"{path.name}: {module}"
        for path in _python_files(LIBRARY)
        for module, _ in _imports(path)
        if module == LAB or module.startswith(f"{LAB}.")
    ]
    assert not offenders, f"survive_rag must not import {LAB}: {offenders}"


def test_lab_may_import_the_library() -> None:
    """The dependency is meant to run this way; assert it actually does."""
    used = {
        module
        for path in _python_files(LAB)
        for module, _ in _imports(path)
        if module.startswith(LIBRARY)
    }
    assert used, "the lab should be exercising the library it measures"


def test_heavy_dependencies_are_imported_lazily_in_the_library() -> None:
    """The lexical path must keep working with nothing installed.

    A top-level ``import numpy`` in a module that the package imports on
    startup would make the zero-dependency claim false, and would break the
    CI job that deliberately installs nothing.
    """
    offenders = []
    for path in _python_files(LIBRARY):
        for module, column in _imports(path):
            root = module.split(".")[0]
            if root in LAZY_ONLY and column == 0 and path.name not in {
                "dense.py",
                "embedder.py",
                "embedder_onnx.py",
            }:
                offenders.append(f"{path.name}: {module}")
    assert not offenders, f"import these lazily: {offenders}"


# The modules that legitimately need a heavy dependency at import time. Every
# other module in the library must import with none of them installed.
HEAVY_MODULES = {"dense.py", "embedder.py", "embedder_onnx.py", "vectors.py"}
# __main__ runs the CLI as a side effect of being imported.
NOT_IMPORTABLE = {"__init__.py", "__main__.py"}


def test_every_light_module_imports_without_numpy() -> None:
    """Import each module with the heavy packages blocked.

    Checking the import *statements* is not enough, and the gap is not
    theoretical: the earlier version of this test named three modules by hand
    and the static check above ignores relative imports entirely. A new module
    that did ``from .vectors import export_vectors`` at the top therefore
    dragged numpy onto the lexical path, passed every local test because numpy
    was installed, and only failed in CI — which installs nothing.

    Importing every module for real is the only version of this check that
    cannot be routed around.
    """
    import subprocess
    import sys

    root = Path(__file__).resolve().parents[1]
    modules = sorted(
        ".".join(path.relative_to(root).with_suffix("").parts)
        for path in _python_files(LIBRARY)
        if path.name not in HEAVY_MODULES | NOT_IMPORTABLE
    )

    code = (
        "import sys, importlib\n"
        "BLOCKED = ('numpy','torch','onnxruntime','sentence_transformers','tokenizers')\n"
        "class Block:\n"
        "    def find_module(self, name, path=None):\n"
        "        if name.split('.')[0] in BLOCKED:\n"
        "            raise AssertionError(name + ' reached at import time')\n"
        "sys.meta_path.insert(0, Block())\n"
        f"for name in {modules!r}:\n"
        "    importlib.import_module(name)\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_the_lab_cli_runs_without_the_heavy_dependencies() -> None:
    """`evals validate` and the lexical commands must work with nothing installed.

    The lab is allowed to depend on torch and onnxruntime; its CLI is not. Every
    command module is imported just to register its parser, so one top-level
    import of an embedding backend in a command nobody asked for makes the whole
    CLI unusable in CI. That has now happened once, which is why it is a test.
    """
    import subprocess
    import sys

    code = (
        "import sys\n"
        "BLOCKED = ('numpy','torch','onnxruntime','sentence_transformers','tokenizers')\n"
        "class Block:\n"
        "    def find_module(self, name, path=None):\n"
        "        if name.split('.')[0] in BLOCKED:\n"
        "            raise AssertionError(name + ' reached at import time')\n"
        "sys.meta_path.insert(0, Block())\n"
        "from evals.cli import build_parser\n"
        "build_parser()\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=Path(__file__).resolve().parents[1],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("package", [LIBRARY, LAB])
def test_no_module_exceeds_the_line_limit(package: str) -> None:
    """The project's own rule: split proactively rather than after the fact."""
    too_long = {
        path.name: len(path.read_text(encoding="utf-8").splitlines())
        for path in _python_files(package)
        if len(path.read_text(encoding="utf-8").splitlines()) > 200
    }
    assert not too_long, f"over 200 lines: {too_long}"

#!/usr/bin/env python3
"""Patch FlashQLA so SM70/SM75 legacy imports do not trip SM90-only paths."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path


def write_text(path: Path, content: str) -> None:
    if not path.exists():
        raise SystemExit(f"missing FlashQLA file: {path}")
    path.write_text(content, encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: patch_flashqla_sm75_imports.py <flashqla_dir> <patch_dir>"
        )

    root = Path(sys.argv[1]).resolve()
    patch_root = Path(sys.argv[2]).resolve()

    write_text(
        root / "flash_qla" / "__init__.py",
        '''# Copyright (c) 2026 The Qwen team, Alibaba Group.
# Licensed under The MIT License [see LICENSE for details]

__version__ = "0.1.0"

try:
    from flash_qla.ops.gated_delta_rule.chunk import (
        chunk_gated_delta_rule_fwd,
        chunk_gated_delta_rule_bwd,
        chunk_gated_delta_rule,
    )
except (ImportError, OSError, RuntimeError, ValueError):
    chunk_gated_delta_rule_fwd = None
    chunk_gated_delta_rule_bwd = None
    chunk_gated_delta_rule = None

__all__ = [
    "chunk_gated_delta_rule_fwd",
    "chunk_gated_delta_rule_bwd",
    "chunk_gated_delta_rule",
]
''',
    )
    write_text(
        root / "flash_qla" / "ops" / "__init__.py",
        '''# Copyright (c) 2026 The Qwen team, Alibaba Group.
# Licensed under The MIT License [see LICENSE for details]

try:
    from .gated_delta_rule import chunk_gated_delta_rule
except (ImportError, OSError, RuntimeError, ValueError):
    chunk_gated_delta_rule = None

__all__ = ["chunk_gated_delta_rule"]
''',
    )
    write_text(
        root / "flash_qla" / "ops" / "gated_delta_rule" / "__init__.py",
        '''# Copyright (c) 2026 The Qwen team, Alibaba Group.
# Licensed under The MIT License [see LICENSE for details]

try:
    from .chunk import chunk_gated_delta_rule
except (ImportError, OSError, RuntimeError, ValueError):
    chunk_gated_delta_rule = None

__all__ = ["chunk_gated_delta_rule"]
''',
    )

    files = (
        (
            patch_root / "sm_legacy.py",
            root / "flash_qla" / "ops" / "gated_delta_rule" / "legacy" / "sm_legacy.py",
        ),
        (
            patch_root / "gdn_forward.cu",
            root
            / "flash_qla"
            / "ops"
            / "gated_delta_rule"
            / "legacy"
            / "csrc"
            / "gdn_forward.cu",
        ),
    )
    for src, dst in files:
        if not src.exists():
            raise SystemExit(f"missing FlashQLA SM75 patch file: {src}")
        if not dst.exists():
            raise SystemExit(f"missing FlashQLA target file: {dst}")
        shutil.copyfile(src, dst)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

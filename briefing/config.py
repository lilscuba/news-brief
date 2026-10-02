from __future__ import annotations

import os
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_config(path: Path | None = None) -> dict:
    path = path or ROOT / "config.toml"
    # utf-8-sig tolerates a BOM left behind by Windows editors.
    cfg = tomllib.loads(path.read_text(encoding="utf-8-sig"))
    for var, (section, key) in {
        "CLAUDE_MODEL": ("claude", "model"),
        "GEMINI_MODEL": ("gemini", "model"),
        "AI_PROVIDER": ("ai", "provider"),
    }.items():
        if value := env(var):
            cfg.setdefault(section, {})[key] = value
    # Lets the setup script / a repo variable switch AI summaries on without editing this file.
    if (value := env("SUMMARIZE")) is not None:
        cfg["digest"]["summarize"] = value.lower() in ("1", "true", "yes", "on")
    return cfg


def env(name: str) -> str | None:
    """Read an optional secret; empty strings (unset GitHub secrets) count as missing."""
    value = os.environ.get(name, "").strip()
    return value or None

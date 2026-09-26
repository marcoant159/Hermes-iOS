"""Allowlist and parsing for mobile-requested model overrides.

Overrides use the ``provider/model`` form so they can be forwarded to the
Hermes API server as separate ``provider`` and ``model`` fields (or to the
CLI as ``--provider``/``--model``).
"""

from __future__ import annotations

SUPPORTED_MODEL_OVERRIDES = frozenset({
    "openai-codex/gpt-6-luna",
    "openai-codex/gpt-6-astra",
    "gemini/gemini-3.8-flash",
    "opencode-go/deepseek-v4.1-flash",
})

# Older app builds sent the bare Gemini model name; map it to the canonical
# provider/model form so existing installs keep working.
LEGACY_MODEL_OVERRIDES = {
    "gemini-3.8-flash": "gemini/gemini-3.8-flash",
}


def parse_model_override(value: str | None) -> tuple[str, str] | None:
    """Return ``(provider, model)`` for a supported override.

    Returns ``None`` when no override was requested. Raises ``ValueError``
    for an unsupported override so the caller can fail the job.
    """
    if not value:
        return None

    normalized = LEGACY_MODEL_OVERRIDES.get(value, value)
    if normalized not in SUPPORTED_MODEL_OVERRIDES:
        raise ValueError(f"Unsupported model override: {value!r}")

    provider, model = normalized.split("/", 1)
    return provider, model

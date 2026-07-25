"""Chat platform adapters.

The engine knows nothing about chat platforms. An adapter does three
things: decide whether an incoming message triggers an eval (extract_code),
build an EvalRequest with the platform's idea of nick/channel, and format
and deliver the reply. Slack is the first adapter (issue #2); discord slots
in beside it as a new module, not a refactor.
"""

from __future__ import annotations

import re

# same default the perl bot shipped: "tcl expr 1+1"
DEFAULT_TRIGGER = re.compile(r"^\s*tcl\s")


def extract_code(text: str, trigger: re.Pattern[str] = DEFAULT_TRIGGER) -> str | None:
    """Return the code portion of a triggering message, or None."""
    if text is None:
        return None
    match = trigger.search(text)
    if not match:
        return None
    return trigger.sub("", text, count=1)


def chunk_output(text: str, max_chunk: int, max_chunks: int) -> list[str]:
    """Split output for platforms with message size limits; cap total chunks
    so one eval can't flood a channel."""
    lines: list[str] = []
    for line in text.split("\n"):
        while len(line) > max_chunk:
            lines.append(line[:max_chunk])
            line = line[max_chunk:]
        lines.append(line)
    if len(lines) > max_chunks:
        total = len(lines)
        lines = lines[: max_chunks - 1]
        lines.append(f"error: output truncated to {max_chunks - 1} of {total} lines total")
    return lines

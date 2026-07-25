"""Chat platform adapters.

The engine knows nothing about chat platforms. An adapter does three
things: decide whether an incoming message triggers an eval (extract_code),
build an EvalRequest with the platform's idea of nick/channel, and format
and deliver the reply. Slack is the first adapter (issue #2); discord slots
in beside it as a new module, not a refactor.
"""

from __future__ import annotations

import re
import time
from collections import deque

# same default the perl bot shipped: "tcl expr 1+1", but case-insensitive:
# phone keyboards autocapitalize the first word, so half the messages from
# mobile arrive as "Tcl ..." and would otherwise be silently ignored
DEFAULT_TRIGGER = re.compile(r"^\s*tcl\s", re.IGNORECASE)


def extract_code(text: str, trigger: re.Pattern[str] = DEFAULT_TRIGGER) -> str | None:
    """Return the code portion of a triggering message, or None."""
    if text is None:
        return None
    match = trigger.search(text)
    if not match:
        return None
    return trigger.sub("", text, count=1)


class ChatLog:
    """Recent non-trigger chatter per channel, fed to evals as [log].

    Same shape the perl bot kept: (unix_ts, nick, mask, text) rows,
    accumulated between evals and drained (slurped) by the next one.
    In-memory only — on Lambda this survives per warm container, which
    matches how ephemeral the old in-process log was.
    """

    def __init__(self, max_lines: int = 100):
        self._max = max_lines
        self._logs: dict[str, deque] = {}

    def append(self, channel: str, nick: str, mask: str | None, text: str) -> None:
        log = self._logs.setdefault(channel, deque(maxlen=self._max))
        log.append((int(time.time()), nick, mask or "", text))

    def slurp(self, channel: str) -> tuple[tuple, ...]:
        log = self._logs.pop(channel, None)
        return tuple(log) if log else ()


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

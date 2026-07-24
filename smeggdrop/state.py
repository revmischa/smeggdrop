"""File-backed state store, byte-compatible with the perl bot.

Layout: <root>/{procs,vars}/_index maps names to sha1(name); each sha1-named
file holds the serialized value. Values are opaque at this layer —
serialization formats live in the interp layer.

Names come out of the sandbox, so nothing name-derived ever becomes a file
path: files are always named by the sha1 of the name, which also makes path
traversal a non-issue. The engine additionally refuses to persist names
that would corrupt the brace-delimited index format.

A deleted entry is written as an empty file (what the perl bot did); loaders
skip and clean those up.
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
from pathlib import Path
from typing import Mapping, Protocol

log = logging.getLogger(__name__)

CATEGORIES = ("procs", "vars")
INDEX_LINE = re.compile(r"^\{(.*)\}\s+([0-9a-f]{40})$")


class StateStore(Protocol):
    def load(self, category: str) -> dict[str, str]: ...

    def save_many(self, category: str, changes: Mapping[str, str | None]) -> None: ...


def name_sha1(name: str) -> str:
    return hashlib.sha1(name.encode("utf-8")).hexdigest()


def open_store(location: str) -> StateStore:
    """Open a state store from a path or an s3:// uri."""
    if location.startswith("s3://"):
        from smeggdrop.state_s3 import S3StateStore

        return S3StateStore.from_uri(location)
    return FileStateStore(location)


class FileStateStore:
    def __init__(self, root: Path | str):
        self.root = Path(root)
        self._indices: dict[str, dict[str, str]] = {}
        for category in CATEGORIES:
            (self.root / category).mkdir(parents=True, exist_ok=True)

    def load(self, category: str) -> dict[str, str]:
        index = self._read_index(category)
        out: dict[str, str] = {}
        deleted: list[str] = []
        for name, sha in index.items():
            path = self.root / category / sha
            try:
                data = path.read_text(encoding="utf-8", errors="replace")
            except FileNotFoundError:
                # damage, not deletion — keep the entry so the loss stays
                # visible (and recoverable if the file turns up)
                log.warning("%s/%s: data file %s missing", category, name, sha)
                continue
            if not data:
                # deletion marker: clean up the file like the perl loader
                # did, and drop the index entry so deletes don't accumulate
                path.unlink(missing_ok=True)
                deleted.append(name)
                continue
            out[name] = data
        for name in deleted:
            del index[name]
        self._indices[category] = index
        if deleted:
            self._write_index(category, index)
        return out

    def save_many(self, category: str, changes: Mapping[str, str | None]) -> None:
        index = self._indices.setdefault(category, self._read_index(category))
        directory = self.root / category
        for name, value in changes.items():
            sha = name_sha1(name)
            (directory / sha).write_text(value if value is not None else "", encoding="utf-8")
            index[name] = sha
        self._write_index(category, index)

    def _read_index(self, category: str) -> dict[str, str]:
        path = self.root / category / "_index"
        if not path.exists():
            return {}
        index: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            m = INDEX_LINE.match(line)
            if m:
                index[m.group(1)] = m.group(2)
                continue
            parts = line.split()
            if len(parts) == 2:
                index[parts[0]] = parts[1]
            else:
                log.warning("%s/_index: skipping malformed line %r", category, line[:80])
        return index

    def _write_index(self, category: str, index: dict[str, str]) -> None:
        path = self.root / category / "_index"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(
            "".join("{%s} %s\n" % (name, index[name]) for name in sorted(index)),
            encoding="utf-8",
        )
        os.replace(tmp, path)

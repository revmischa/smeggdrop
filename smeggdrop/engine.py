"""Versioned Tcl evaluation: snapshot -> eval -> diff -> persist.

All chat input is untrusted; the layers that deal with that here:

- code runs only in the safe slave (interp.py), wall-clock limited per eval
- context values are passed via Tcl list quoting, never interpolated
- host builtins are capped per eval (bot_say floods, curl call count) and
  outbound HTTP goes through security.SafeFetcher
- results are truncated before they reach any chat platform
- persistence is vetted: caps on change count and value size per eval, and
  names that would corrupt the index format are refused

Evals run on one dedicated worker thread: Tcl interps are thread-bound and
the snapshot/diff persistence assumes serial evals anyway. That thread is
also the concurrency control — platform adapters can call eval() from any
thread and evals are serialized.
"""

from __future__ import annotations

import hashlib
import logging
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from smeggdrop.interp import SafeTclInterp, TclError
from smeggdrop.security import FetchError, FetchPolicy, SafeFetcher
from smeggdrop.state import StateStore

log = logging.getLogger(__name__)

CATEGORIES = ("procs", "vars")


@dataclass(frozen=True)
class Limits:
    eval_time_seconds: int = 5
    result_max_chars: int = 65536
    say_max_calls: int = 10
    curl_max_calls: int = 5
    curl_timeout: float = 10.0
    curl_max_bytes: int = 1_000_000
    max_changes_per_eval: int = 200
    max_value_bytes: int = 1_048_576
    max_name_chars: int = 512


@dataclass
class EvalRequest:
    code: str
    nick: str | None = None
    channel: str | None = None
    mask: str | None = None
    nicks: tuple[str, ...] = ()
    # recent channel chatter as (unix_ts, nick, mask, text) rows; reachable
    # in the sandbox via [log]
    loglines: tuple[tuple, ...] = ()


@dataclass
class EvalResult:
    ok: bool
    output: str
    warnings: list[str] = field(default_factory=list)


# tcl sets these automatically whenever an error is caught; persisting them
# is pure churn (the legacy bot did, which is how junk errorInfo entries
# ended up in old state dirs)
AUTOMATIC_VARS = frozenset({"errorInfo", "errorCode"})


def diff_category(pre: dict[str, str], post: dict[str, str]) -> dict[str, str | None]:
    """Changed entries between snapshots; None means deleted."""
    changed: dict[str, str | None] = {}
    for name in pre.keys() | post.keys():
        if name.startswith("context::") or name in AUTOMATIC_VARS:
            continue
        a, b = pre.get(name), post.get(name)
        if a != b:
            changed[name] = b
    return changed


class Engine:
    def __init__(
        self,
        store: StateStore,
        *,
        tcl_dir: Path | str | None = None,
        limits: Limits | None = None,
        fetcher: SafeFetcher | None = None,
        words_file: Path | str | None = None,
    ):
        self.store = store
        self.limits = limits or Limits()
        self.fetcher = fetcher or SafeFetcher(
            FetchPolicy(timeout=self.limits.curl_timeout, max_bytes=self.limits.curl_max_bytes)
        )
        self.words_file = Path(words_file) if words_file else None
        self._words: tuple[str, ...] | None = None
        self._say: Callable[[str], None] | None = None
        self._say_calls = 0
        self._curl_calls = 0
        self.load_errors: dict[str, str] = {}
        self._closed = False
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="smeggdrop-tcl")
        self._executor.submit(self._init_interp, tcl_dir).result()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._executor.submit(lambda: self.interp.close())
        self._executor.shutdown(wait=True)

    # -- public API ----------------------------------------------------

    def eval(
        self,
        req: EvalRequest,
        say: Callable[[str], None] | None = None,
        timeout: float | None = None,
    ) -> EvalResult:
        """Evaluate chat-supplied code. `say` receives any core::bot_say
        output mid-eval. Blocks until done; evals are serialized."""
        future = self._executor.submit(self._eval, req, say)
        return future.result(timeout if timeout is not None else self.limits.eval_time_seconds + 30)

    # -- worker-thread internals ---------------------------------------

    def _init_interp(self, tcl_dir) -> None:
        self.interp = SafeTclInterp(
            tcl_dir=tcl_dir,
            builtins={
                "core::print": self._b_print,
                "core::sha1": self._b_sha1,
                "core::curl": self._b_curl,
                "core::http": self._b_http,
                "core::urlencode": self._b_urlencode,
                "core::bot_say": self._b_say,
                "core::words": self._b_words,
            },
        )
        for category, install in (
            ("procs", self.interp.install_proc),
            ("vars", self.interp.install_var),
        ):
            for name, payload in self.store.load(category).items():
                try:
                    install(name, payload)
                except (TclError, ValueError) as e:
                    self.load_errors[f"{category}/{name}"] = str(e)
                    log.warning("failed to load %s %r: %s", category, name, e)
        self.interp.alias_global_commands()

    def _eval(self, req: EvalRequest, say) -> EvalResult:
        self._say = say
        self._say_calls = 0
        self._curl_calls = 0
        warnings: list[str] = []
        try:
            interp = self.interp
            interp.set_context(
                nick=req.nick,
                mask=req.mask,
                channel=req.channel,
                command=req.code,
                nicks=req.nicks,
                log=req.loglines,
            )
            interp.set_command_vars(
                nick=req.nick, mask=req.mask, channel=req.channel, line=req.code
            )
            interp.eval("catch {commands::increment_eval_count}")

            pre = {c: getattr(interp, c)() for c in CATEGORIES}
            try:
                output = interp.eval_limited(req.code, self.limits.eval_time_seconds)
            except TclError as e:
                return EvalResult(False, str(e))
            post = {c: getattr(interp, c)() for c in CATEGORIES}

            for category in CATEGORIES:
                changes = diff_category(pre[category], post[category])
                changes = self._vet_changes(category, changes, warnings)
                if changes:
                    self.store.save_many(category, changes)

            if len(output) > self.limits.result_max_chars:
                output = (
                    output[: self.limits.result_max_chars]
                    + f"\n(output truncated at {self.limits.result_max_chars} chars)"
                )
            return EvalResult(True, output, warnings)
        finally:
            self._say = None

    def _vet_changes(
        self, category: str, changes: dict[str, str | None], warnings: list[str]
    ) -> dict[str, str | None]:
        if len(changes) > self.limits.max_changes_per_eval:
            warnings.append(
                f"{category}: {len(changes)} changes exceeds the per-eval limit "
                f"of {self.limits.max_changes_per_eval}; nothing persisted"
            )
            return {}
        vetted: dict[str, str | None] = {}
        for name, value in changes.items():
            if (
                len(name) > self.limits.max_name_chars
                or any(c in name for c in "{}\\")
                or any(c in name for c in "\n\r")
            ):
                warnings.append(f"{category}: not persisting unsafe name {name[:40]!r}")
                continue
            if value is not None and len(value.encode("utf-8")) > self.limits.max_value_bytes:
                warnings.append(f"{category}: not persisting {name!r} (value too large)")
                continue
            vetted[name] = value
        return vetted

    # -- builtins exposed to the sandbox -------------------------------
    # args arrive as strings from Tcl; raising becomes a Tcl error

    def _b_print(self, *args) -> str:
        log.info("tcl print: %s", " ".join(str(a) for a in args))
        return ""

    def _b_sha1(self, text="") -> str:
        return hashlib.sha1(str(text).encode("utf-8")).hexdigest()

    def _b_curl(self, url="") -> tuple[str, str]:
        status, _headers, body = self._fetch("core::curl", str(url))
        return (str(status), body)

    def _b_http(self, method="GET", url="", body="") -> tuple[str, tuple, str]:
        """[code {header value ...} body] — the shape the old http.tcl returned."""
        status, headers, resp_body = self._fetch("core::http", str(url), str(method), str(body))
        flat: list[str] = []
        for k, v in headers.items():
            flat.extend((k, v))
        return (str(status), tuple(flat), resp_body)

    def _fetch(self, who: str, url: str, method: str = "GET", body: str | None = None):
        self._curl_calls += 1
        if self._curl_calls > self.limits.curl_max_calls:
            raise TclError(f"{who}: limit of {self.limits.curl_max_calls} fetches per eval")
        try:
            return self.fetcher.fetch(url, method=method, body=body)
        except FetchError as e:
            raise TclError(f"{who}: {e}") from e

    def _b_urlencode(self, text="") -> str:
        return urllib.parse.quote_plus(str(text))

    def _b_say(self, *args) -> str:
        self._say_calls += 1
        if self._say_calls > self.limits.say_max_calls:
            raise TclError(f"core::bot_say: limit of {self.limits.say_max_calls} messages per eval")
        text = " ".join(str(a) for a in args)
        if self._say is not None:
            self._say(text)
        else:
            log.info("bot_say (no channel attached): %s", text)
        return ""

    def _b_words(self) -> tuple[str, ...]:
        if self.words_file is None:
            raise TclError("core::words: no words file configured")
        if self._words is None:
            self._words = tuple(self.words_file.read_text(encoding="utf-8").split("\n"))
        return self._words

"""Audit saved state: which procs load, reference dead commands, or crash.

The runtime state has years of procs written in chat against the old
interpreter — tclcurl-era http helpers, eggdrop leftovers. This loads a
state dir into a throwaway sandbox and reports, per proc:

- does it install cleanly (`proc` succeeds)?
- does its body reference commands that don't exist? split into
  `broken_refs` (known-hidden safe-interp commands and dead library
  prefixes — definitely broken) and `unknown_refs` (heuristic: a word in
  command position that resolves to nothing — may be a false positive for
  data words in braces)
- if it's callable with zero args, does it actually run?

Nothing is persisted: the audit interp never touches a save path, curl is
stubbed out, bot_say is captured. Use this after syncing the production
state dir to see exactly what the port broke, fix, re-run, repeat.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import asdict, dataclass, field

from smeggdrop.interp import SafeTclInterp, TclError
from smeggdrop.state import StateStore

# hidden in safe interps: anything referencing these is broken by design
SAFE_HIDDEN = {
    "cd", "encoding", "exec", "exit", "fconfigure", "file", "glob",
    "load", "open", "pwd", "socket", "source", "unload", "vwait",
}
# gone with the perl host process
DEAD_PREFIXES = ("http::", "curl::", "twitter::", "tclcurl")

# a bareword in command position: start of script/line, or after [ or ;
CMD_POSITION = re.compile(r"(?:^|[\[;\n])\s*([A-Za-z_][\w:.@?!+-]*)", re.M)


@dataclass
class ProcAudit:
    name: str
    loaded: bool = True
    load_error: str | None = None
    broken_refs: list[str] = field(default_factory=list)
    unknown_refs: list[str] = field(default_factory=list)
    ran: bool = False
    run_ok: bool | None = None
    run_error: str | None = None

    @property
    def healthy(self) -> bool:
        return self.loaded and not self.broken_refs and self.run_ok is not False


@dataclass
class AuditReport:
    procs: list[ProcAudit]
    var_load_errors: dict[str, str]

    def summary(self) -> dict[str, int]:
        return {
            "total": len(self.procs),
            "load_failures": sum(1 for p in self.procs if not p.loaded),
            "broken_refs": sum(1 for p in self.procs if p.broken_refs),
            "unknown_refs": sum(1 for p in self.procs if p.unknown_refs),
            "ran": sum(1 for p in self.procs if p.ran),
            "run_failures": sum(1 for p in self.procs if p.run_ok is False),
            "var_load_failures": len(self.var_load_errors),
        }

    def to_dict(self) -> dict:
        return {
            "summary": self.summary(),
            "procs": [asdict(p) for p in self.procs],
            "var_load_errors": self.var_load_errors,
        }


def audit_state(
    store: StateStore,
    *,
    tcl_dir=None,
    run: bool = True,
    time_limit: int = 2,
) -> AuditReport:
    said: list[str] = []
    interp = SafeTclInterp(
        tcl_dir=tcl_dir,
        builtins={
            "core::print": lambda *a: "",
            "core::sha1": lambda t="": hashlib.sha1(str(t).encode()).hexdigest(),
            "core::bot_say": lambda *a: said.append(" ".join(str(x) for x in a)) or "",
            "core::curl": _curl_stub,
            "core::words": lambda: (),
        },
    )
    try:
        reports: dict[str, ProcAudit] = {}
        for name, payload in sorted(store.load("procs").items()):
            report = ProcAudit(name)
            try:
                interp.install_proc(name, payload)
            except TclError as e:
                report.loaded = False
                report.load_error = str(e)
            reports[name] = report

        var_errors: dict[str, str] = {}
        for name, payload in sorted(store.load("vars").items()):
            try:
                interp.install_var(name, payload)
            except (TclError, ValueError) as e:
                var_errors[name] = str(e)

        interp.alias_global_commands()

        for name, report in reports.items():
            if not report.loaded:
                continue
            body = interp.eval(("info", "body", name))
            for ref in sorted(set(CMD_POSITION.findall(body))):
                if ref == name:
                    continue
                if interp.eval(("info", "commands", ref)) != "":
                    continue
                if ref in SAFE_HIDDEN or ref.startswith(DEAD_PREFIXES):
                    report.broken_refs.append(ref)
                else:
                    report.unknown_refs.append(ref)

        if run:
            interp.set_context(
                nick="audit", mask="audit@audit", channel="#audit",
                command="", nicks=("audit",),
            )
            interp.set_command_vars(nick="audit", mask="audit@audit", channel="#audit", line="")
            for name, report in reports.items():
                if not report.loaded or not _callable_without_args(interp, name):
                    continue
                report.ran = True
                try:
                    interp.eval_limited((name,), time_limit)
                    report.run_ok = True
                except TclError as e:
                    report.run_ok = False
                    report.run_error = str(e)

        return AuditReport(list(reports.values()), var_errors)
    finally:
        interp.close()


def _curl_stub(*args):
    raise TclError("core::curl is disabled during audit")


def _callable_without_args(interp: SafeTclInterp, name: str) -> bool:
    try:
        args = interp.splitlist(interp.eval(("info", "args", name)))
    except TclError:
        return False
    for arg in args:
        if arg == "args":
            continue  # varargs: zero is fine
        if interp.eval(("info", "default", name, arg, "::_audit_default")) != "1":
            return False
    return True

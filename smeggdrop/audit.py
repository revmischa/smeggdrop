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
import urllib.parse
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
    shadowed: bool = False  # a bootstrap alias (cache, meta, ...) hides it
    broken_refs: list[str] = field(default_factory=list)
    unknown_refs: list[str] = field(default_factory=list)
    ran: bool = False
    run_ok: bool | None = None
    run_error: str | None = None
    needs_network: bool = False  # only "failed" because audit stubs the network
    arity: int | None = None  # required args, when it takes any
    arg_mismatch: bool = False  # failed on the audit's dummy args, not broken
    timed_out: bool = False  # too slow for the audit's limit, not necessarily broken

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
            "shadowed": sum(1 for p in self.procs if p.shadowed),
            "broken_refs": sum(1 for p in self.procs if p.broken_refs),
            "unknown_refs": sum(1 for p in self.procs if p.unknown_refs),
            "ran": sum(1 for p in self.procs if p.ran),
            "run_ok": sum(1 for p in self.procs if p.run_ok is True),
            "run_failures": sum(1 for p in self.procs if p.run_ok is False),
            "needs_network": sum(1 for p in self.procs if p.needs_network),
            "arg_mismatch": sum(1 for p in self.procs if p.arg_mismatch),
            "timed_out": sum(1 for p in self.procs if p.timed_out),
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
    call_with_args: bool = False,
    arg_value: str = "test",
) -> AuditReport:
    said: list[str] = []
    interp = SafeTclInterp(
        tcl_dir=tcl_dir,
        builtins={
            "core::print": lambda *a: "",
            "core::sha1": lambda t="": hashlib.sha1(str(t).encode()).hexdigest(),
            "core::bot_say": lambda *a: said.append(" ".join(str(x) for x in a)) or "",
            "core::curl": _network_stub,
            "core::http": _network_stub,
            "core::urlencode": lambda t="": urllib.parse.quote_plus(str(t)),
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
            try:
                body = interp.eval(("info", "body", name))
            except TclError:
                # a bootstrap alias with the same global name replaced this
                # saved proc after load, exactly like the perl loader did;
                # the saved body is inert so there's nothing to scan or run
                report.shadowed = True
                continue
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
                # a plausible line of chatter: procs that read [log] should
                # exercise their real path, not fail on an unset variable
                log=((0, "audit", "audit@audit", "hello"),),
            )
            interp.set_command_vars(nick="audit", mask="audit@audit", channel="#audit", line="")
            for name, report in reports.items():
                if not report.loaded or report.shadowed:
                    continue
                required = _required_args(interp, name)
                if required is None:
                    continue
                report.arity = len(required)
                if required and not call_with_args:
                    continue  # zero-arg procs only

                # procs that take arguments get a generic token per slot;
                # it exercises far more of the library than zero-arg calls
                # alone, at the cost of some "wrong kind of argument" noise
                # that _looks_like_arg_mismatch sorts back out
                call = (name, *[arg_value] * len(required))
                report.ran = True
                try:
                    interp.eval_limited(call, time_limit)
                    report.run_ok = True
                except TclError as e:
                    error = str(e)
                    if NETWORK_STUB_MARKER in error:
                        # it made it all the way to the fetcher; that's a
                        # working proc, the audit just won't do network
                        report.needs_network = True
                        report.run_ok = None
                    elif "time limit exceeded" in error:
                        # slow, or an infinite loop; the audit can't tell
                        # which, and its limit is tighter than the bot's
                        report.timed_out = True
                        report.run_ok = None
                        report.run_error = error
                    elif required and _looks_like_arg_mismatch(error):
                        report.arg_mismatch = True
                        report.run_ok = None
                        report.run_error = error
                    else:
                        report.run_ok = False
                        report.run_error = error

        return AuditReport(list(reports.values()), var_errors)
    finally:
        interp.close()


NETWORK_STUB_MARKER = "network is disabled during audit"


def _network_stub(*args):
    raise TclError(NETWORK_STUB_MARKER)


def _required_args(interp: SafeTclInterp, name: str) -> list[str] | None:
    """Args with no default, i.e. what a caller must supply. None if the
    proc can't be introspected."""
    try:
        args = interp.splitlist(interp.eval(("info", "args", name)))
    except TclError:
        return None
    required = []
    for arg in args:
        if arg == "args":
            continue  # varargs: zero is fine
        if interp.eval(("info", "default", name, arg, "::_audit_default")) != "1":
            required.append(arg)
    return required


def _callable_without_args(interp: SafeTclInterp, name: str) -> bool:
    required = _required_args(interp, name)
    return required is not None and not required


# Errors that mean "the audit's dummy argument was wrong for this proc",
# not "this proc is broken". A proc wanting a number, a nick that exists, or
# a specific keyword will reject a generic token, and that is not a defect.
ARG_MISMATCH_PATTERNS = (
    "expected integer",
    "expected floating-point",
    "expected boolean",
    "non-numeric string",
    "can't use empty string as operand",
    "expected version number",
    "not in valid range",
    "no such element in array",
    "no such variable",
    "must be ",
    "bad option",
    "bad index",
    "bad command",
    "invalid bareword",
    "divide by zero",
    "list element in braces",
    "unmatched open brace",
    "wrong # args",
)


def _looks_like_arg_mismatch(error: str) -> bool:
    lowered = error.lower()
    return any(p in lowered for p in ARG_MISMATCH_PATTERNS)

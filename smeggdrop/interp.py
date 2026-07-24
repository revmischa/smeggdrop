"""Safe Tcl slave interpreter on top of the stdlib tkinter binding.

tkinter.Tcl() embeds a real Tcl interpreter (no Tk, no display required).
We use it as the trusted master and evaluate all chat-supplied code in a
`interp create -safe` slave, the same layout the perl implementation used.
The safe slave has no exec/open/file/socket/source/etc; anything it needs
from the outside world goes through explicitly aliased commands.

Chat input is untrusted. Nothing user-controlled is ever interpolated into
a Tcl script string here: scripts either come in whole (the code being
evaluated, which runs inside the sandbox) or are built as Tcl lists via
tuples, which tkinter quotes correctly.

Tcl interpreters are thread-bound: create and use an instance from a single
thread. Engine owns a dedicated worker thread for exactly this reason.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path
from tkinter import Tcl, TclError

__all__ = ["SafeTclInterp", "TclError"]

log = logging.getLogger(__name__)

DEFAULT_TCL_DIR = Path(__file__).parent / "tcl"
BOOTSTRAP_FILES = (
    "meta_proc.tcl",
    "commands.tcl",
    "meta.tcl",
    "cache.tcl",
    "httpx.tcl",
    "bootstrap.tcl",
)
SLAVE = "smeggdrop"
SCRIPT_VAR = "::_smeggdrop_script"


class SafeTclInterp:
    def __init__(self, tcl_dir: Path | str | None = None, builtins: dict | None = None):
        # keep the Tk wrapper alive; the Tkapp on .tk is what we talk to
        self._app = Tcl()
        self.tk = self._app.tk
        self.slave = SLAVE
        self.tk.call("interp", "create", "-safe", self.slave)

        tcl_dir = Path(tcl_dir) if tcl_dir else DEFAULT_TCL_DIR
        for name in BOOTSTRAP_FILES:
            path = tcl_dir / name
            if path.exists():
                self.tk.call("interp", "invokehidden", self.slave, "source", str(path))

        # safe interps can't initialize `clock format` themselves (needs
        # tzdata off disk), so run clock in the master on the slave's behalf
        self.tk.call("interp", "alias", self.slave, "clock", "", "clock")

        # `encoding` is hidden in safe interps because `encoding system`
        # mutates process state; the read-only subcommands are harmless and
        # plenty of saved procs use them
        self.tk.call(
            "proc", "::_smeggdrop_encoding", "args",
            'set sub [lindex $args 0]\n'
            'if {$sub ni {convertfrom convertto names}} '
            '{error "encoding $sub is not allowed in the sandbox"}\n'
            "uplevel #0 [linsert $args 0 encoding]",
        )
        self.tk.call("interp", "alias", self.slave, "encoding", "", "::_smeggdrop_encoding")

        for name, fn in (builtins or {}).items():
            self.register_builtin(name, fn)

    def close(self) -> None:
        try:
            self.tk.call("interp", "delete", self.slave)
        except TclError:
            pass

    # -- evaluation ----------------------------------------------------

    def eval(self, script) -> str:
        """Evaluate in the slave; returns the result's string rep.

        `script` is either a str (a full Tcl script — only ever sandbox
        input or trusted constants) or a tuple (one command, each element
        quoted as a list word by tkinter — safe for untrusted values).
        """
        self.tk.setvar(SCRIPT_VAR, script)
        try:
            return self.tk.eval(f"interp eval {self.slave} ${SCRIPT_VAR}")
        finally:
            try:
                self.tk.unsetvar(SCRIPT_VAR)
            except TclError:
                pass

    def eval_limited(self, script, seconds: int) -> str:
        """Evaluate with a wall-clock limit enforced by the master.

        Slaves cannot modify their own limits, so sandboxed code can't
        lift this.
        """
        deadline = int(time.time()) + max(1, int(seconds))
        self.tk.call("interp", "limit", self.slave, "time", "-seconds", deadline)
        try:
            return self.eval(script)
        finally:
            self.tk.call("interp", "limit", self.slave, "time", "-seconds", "")

    def splitlist(self, value) -> tuple[str, ...]:
        return tuple(str(v) for v in self.tk.splitlist(value))

    # -- host <-> slave plumbing ---------------------------------------

    def register_builtin(self, name: str, fn) -> None:
        """Expose a python callable to the slave as command `name`.

        The callable receives its Tcl arguments as strings and may return
        str, tuple (becomes a Tcl list) or None. Raising an exception
        becomes a Tcl error in the sandbox.

        _tkinter drops the message of exceptions raised inside command
        callbacks, so the callback returns an (ok|err, payload) pair and a
        master-side trampoline proc re-raises err as a real Tcl error.
        """
        if "::" in name:
            ns = name.rsplit("::", 1)[0]
            self.tk.call("namespace", "eval", ns, "")
            self.eval(("namespace", "eval", ns, ""))

        raw = "::_smeggdrop_raw_" + name.replace("::", "_")

        def wrapped(*args):
            try:
                result = fn(*args)
                return ("ok", "" if result is None else result)
            except Exception as e:  # noqa: BLE001 — becomes a sandbox-side error
                return ("err", str(e) or e.__class__.__name__)

        self.tk.createcommand(raw, wrapped)
        self.tk.call(
            "proc",
            name,
            "args",
            f"set r [uplevel #0 [linsert $args 0 {raw}]]\n"
            'if {[lindex $r 0] eq "err"} {error [lindex $r 1]}\n'
            "return [lindex $r 1]",
        )
        self.tk.call("interp", "alias", self.slave, name, "", name)

    def set_context(self, **vars) -> None:
        """Export the command context (nick, channel, ...) as context::*"""
        self.eval(("namespace", "eval", "::context", ""))
        for k, v in vars.items():
            self.eval(("set", f"::context::{k}", "" if v is None else v))

    def set_command_vars(self, **vars) -> None:
        """Set namespace variables in ::commands (nick, mask, channel, line)."""
        for k, v in vars.items():
            self.eval(("namespace", "eval", "::commands", ("set", k, "" if v is None else v)))

    def alias_global_commands(self) -> None:
        """Alias public ::commands procs to global names (meta, cache, ...),
        mirroring the perl loader. Runs after state load, so these win over
        any similarly-named saved proc, same as before."""
        try:
            procs = self.splitlist(self.eval("namespace eval ::commands {info procs}"))
            hidden = set(self.splitlist(self.eval("commands::get hidden_procs")))
        except TclError:
            return
        for p in procs:
            if p in hidden:
                continue
            self.tk.call("interp", "alias", self.slave, p, self.slave, f"::commands::{p}")

    # -- state snapshot / install --------------------------------------
    # serialization formats are byte-compatible with the perl bot:
    #   proc: "{arglist} {body}"    var: "scalar {value}" | "array {k v ...}"

    def procs(self) -> dict[str, str]:
        out = {}
        for name in self.splitlist(self.eval("info procs")):
            try:
                args = self.arg_spec(name)
                body = self.eval(("info", "body", name))
            except TclError:
                continue
            out[name] = "{%s} {%s}" % (args, body)
        return out

    def arg_spec(self, name: str) -> str:
        """Rebuild a proc's argument list *with* default values.

        `info args` returns bare names, so serializing from it silently
        drops defaults and turns `proc p {{x 1}}` into `proc p {x}` — a
        proc that used to be callable with no arguments stops being one.
        `info default` recovers them.
        """
        spec = []
        for arg in self.splitlist(self.eval(("info", "args", name))):
            has_default = self.eval(("info", "default", name, arg, "::_smeggdrop_default"))
            if has_default == "1":
                default = self.eval(("set", "::_smeggdrop_default"))
                spec.append(self.eval(("list", arg, default)))
            else:
                spec.append(arg)
        self.eval("catch {unset ::_smeggdrop_default}")
        return self.eval(("list", *spec)) if spec else ""

    def vars(self) -> dict[str, str]:
        out = {}
        for name in self.splitlist(self.eval("info vars")):
            try:
                if self.eval(("array", "exists", name)) == "1":
                    out[name] = "array {%s}" % self.eval(("array", "get", name))
                else:
                    out[name] = "scalar {%s}" % self.eval(("set", name))
            except TclError:
                continue  # declared but unset
        return out

    def install_proc(self, name: str, payload: str) -> None:
        self.eval("proc {%s} %s" % (name, payload))

    def install_var(self, name: str, payload: str) -> None:
        kind, _, value = payload.partition(" ")
        if kind == "scalar":
            self.eval("set {%s} %s" % (name, value))
        elif kind == "array":
            self.eval("array set {%s} %s" % (name, value))
        else:
            raise ValueError(f"unknown var payload kind {kind!r}")

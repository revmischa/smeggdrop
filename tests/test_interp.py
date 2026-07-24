import pytest

from smeggdrop.interp import SafeTclInterp, TclError


@pytest.fixture
def interp():
    i = SafeTclInterp()
    yield i
    i.close()


def test_basic_eval(interp):
    assert interp.eval("expr {1 + 1}") == "2"


def test_error_raises(interp):
    with pytest.raises(TclError):
        interp.eval("this-command-does-not-exist")


@pytest.mark.parametrize(
    "script",
    [
        "open /etc/passwd",
        "exec ls",
        "file exists /",
        "socket localhost 80",
        "glob *",
        "exit 0",
    ],
)
def test_dangerous_commands_hidden(interp, script):
    with pytest.raises(TclError):
        interp.eval(script)


def test_clock_aliased_from_master(interp):
    assert "1970" in interp.eval("clock format 0 -gmt 1")


def test_encoding_readonly_subcommands(interp):
    assert interp.eval("encoding convertto utf-8 abc") == "abc"
    assert "utf-8" in interp.eval("encoding names")
    with pytest.raises(TclError, match="not allowed"):
        interp.eval("encoding system iso8859-1")


def test_tuple_args_are_injection_safe(interp):
    hostile = 'a [exec ls] {b} $env(PATH) "; exit'
    interp.eval(("set", "x", hostile))
    assert interp.eval(("set", "x")) == hostile


def test_context_vars_and_accessors(interp):
    interp.set_context(nick="alice", channel="#chan", mask="a@b", command="cmd", nicks=("alice", "bob"))
    assert interp.eval("nick") == "alice"
    assert interp.eval("channel") == "#chan"
    assert interp.eval("set context::nick") == "alice"
    assert interp.splitlist(interp.eval("nicks")) == ("alice", "bob")


def test_alias_compat_proc(interp):
    interp.eval("proc greet {} {return hi}")
    interp.eval("alias hello ::greet")
    assert interp.eval("hello") == "hi"


def test_time_limit_fires_and_interp_survives(interp):
    with pytest.raises(TclError):
        interp.eval_limited("while 1 {}", 1)
    assert interp.eval("expr {2 + 2}") == "4"


def test_slave_cannot_lift_its_own_limit(interp):
    with pytest.raises(TclError):
        interp.eval_limited(
            "interp limit {} time -seconds {}; while 1 {}", 1
        )


def test_snapshot_serialization_roundtrip(interp):
    interp.eval("proc double x {expr {$x * 2}}")
    interp.eval("set scalar_var {hello world}")
    interp.eval("array set arr {a 1 b 2}")

    procs = interp.procs()
    vars_ = interp.vars()
    assert procs["double"] == "{x} {expr {$x * 2}}"
    assert vars_["scalar_var"] == "scalar {hello world}"
    assert vars_["arr"].startswith("array {")

    other = SafeTclInterp()
    try:
        other.install_proc("double", procs["double"])
        other.install_var("scalar_var", vars_["scalar_var"])
        other.install_var("arr", vars_["arr"])
        assert other.eval("double 21") == "42"
        assert other.eval("set scalar_var") == "hello world"
        assert other.eval("set arr(b)") == "2"
    finally:
        other.close()


def test_commands_namespace_aliased_globally(interp):
    interp.alias_global_commands()
    # meta comes from meta.tcl via meta_proc; eval_count starts at -1
    assert interp.eval("meta eval_count") == "-1"
    # hidden procs must not be aliased
    with pytest.raises(TclError):
        interp.eval("get eval_count")

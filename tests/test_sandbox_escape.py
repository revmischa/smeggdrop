"""Adversarial tests: things a hostile chat user would actually try.

The threat model is a stranger in a slack channel who can run arbitrary
Tcl. They must not be able to read the bot's secrets, touch the host, or
reach the operator's network.
"""

import os

import pytest

from smeggdrop.engine import Engine, EvalRequest, Limits
from smeggdrop.state import FileStateStore


@pytest.fixture
def engine(tmp_path):
    e = Engine(FileStateStore(tmp_path), limits=Limits(eval_time_seconds=3))
    yield e
    e.close()


def run(engine, code):
    return engine.eval(EvalRequest(code=code, nick="attacker", channel="#chan"))


@pytest.fixture(autouse=True)
def _secret_in_env(monkeypatch):
    monkeypatch.setenv("SLACK_BOT_TOKEN", "xoxb-super-secret-do-not-leak")


@pytest.mark.parametrize(
    "code",
    [
        "set env(SLACK_BOT_TOKEN)",
        "global env; set env(SLACK_BOT_TOKEN)",
        "set ::env(SLACK_BOT_TOKEN)",
        "array get ::env",
        "info library",
        "exec env",
        "exec sh -c {echo $SLACK_BOT_TOKEN}",
    ],
)
def test_cannot_read_the_bot_token(engine, code):
    # some of these error, some return empty (safe interps have no ::env at
    # all); what matters is that the secret never comes back
    result = run(engine, code)
    assert "xoxb-super-secret" not in result.output


@pytest.mark.parametrize(
    "code",
    [
        "open /etc/passwd",
        "open ~/.aws/credentials",
        "source /etc/passwd",
        "glob /home/*",
        "file readable /etc/shadow",
        "cd /",
        "pwd",
        "exec cat /etc/passwd",
        "load /usr/lib/libc.so.6",
    ],
)
def test_cannot_touch_the_filesystem(engine, code):
    assert not run(engine, code).ok


@pytest.mark.parametrize(
    "code",
    [
        "socket 127.0.0.1 22",
        "socket -server accept 8080",
        "core::curl http://169.254.169.254/latest/meta-data/",
        "core::curl http://127.0.0.1:8080/",
        "core::curl http://192.168.1.1/",
        "core::curl file:///etc/passwd",
        "http get http://10.0.0.1/",
    ],
)
def test_cannot_reach_the_local_network(engine, code):
    result = run(engine, code)
    assert not result.ok
    assert "refusing" in result.output or "invalid command" in result.output


def test_cannot_escape_via_a_nested_interp(engine):
    # safe interps can create children, but they inherit safety and cannot
    # be granted hidden commands by their creator
    result = run(engine, "interp create evil; evil eval {exec ls}")
    assert not result.ok
    result = run(engine, "interp create -safe kid; interp expose kid exec")
    assert not result.ok


def test_cannot_lift_its_own_limits(engine):
    for code in (
        "interp limit {} time -seconds {}",
        "interp limit {} command -value {}",
    ):
        assert not run(engine, code).ok


def test_runaway_loops_are_stopped(engine):
    for code in ("while 1 {}", "while 1 {set x 1}", "proc f {} {f}; f"):
        assert not run(engine, code).ok
        # and the bot keeps serving everyone else afterwards: a limit that
        # stayed tripped would turn one hostile eval into a permanent
        # denial of service for the whole channel
        assert run(engine, "expr {1 + 1}").output == "2"


def test_cannot_exit_or_crash_the_host_process(engine):
    for code in ("exit", "exit 1", "exec kill -9 [pid]"):
        assert not run(engine, code).ok
    assert run(engine, "expr {2 + 2}").output == "4"


def test_cannot_write_outside_the_state_directory(engine, tmp_path):
    # names are hashed, so even a traversal-shaped proc name stays put
    result = run(engine, "proc {../../../../tmp/pwned} {} {return 1}")
    assert result.ok
    assert not (tmp_path.parent.parent / "pwned").exists()
    assert not os.path.exists("/tmp/pwned")


def test_output_flooding_is_capped(tmp_path):
    engine = Engine(
        FileStateStore(tmp_path), limits=Limits(eval_time_seconds=3, result_max_chars=500)
    )
    try:
        result = engine.eval(EvalRequest(code="string repeat 'spam ' 100000"))
        assert len(result.output) < 700
    finally:
        engine.close()


def test_state_cannot_be_stuffed_in_one_eval(tmp_path):
    engine = Engine(
        FileStateStore(tmp_path),
        limits=Limits(eval_time_seconds=3, max_changes_per_eval=10),
    )
    try:
        result = engine.eval(
            EvalRequest(code="for {set i 0} {$i < 500} {incr i} {set junk_$i x}")
        )
        assert result.warnings
    finally:
        engine.close()
    assert FileStateStore(tmp_path).load("vars") == {}

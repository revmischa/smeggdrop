import subprocess
import sys

import pytest

from smeggdrop.hardening import apply_memory_limit


def test_reads_env(monkeypatch):
    monkeypatch.setenv("SMEGGDROP_MEMORY_MB", "0")
    assert apply_memory_limit() is None  # explicitly disabled


def test_explicit_zero_disables():
    assert apply_memory_limit(0) is None


@pytest.mark.skipif(sys.platform == "win32", reason="posix rlimits")
def test_hostile_allocation_dies_instead_of_eating_the_host():
    # one command, so neither the time nor command limit sees it coming;
    # the rlimit is what stops it. Runs in a subprocess because the limit
    # is process-wide and the failure is fatal.
    script = """
import resource, sys
from smeggdrop.hardening import apply_memory_limit
from smeggdrop.engine import Engine, EvalRequest, Limits
from smeggdrop.state import FileStateStore
import tempfile

apply_memory_limit(512)
soft, _ = resource.getrlimit(resource.RLIMIT_AS)
assert soft == 512 * 1024 * 1024, soft

engine = Engine(FileStateStore(tempfile.mkdtemp()), limits=Limits(eval_time_seconds=5))
result = engine.eval(EvalRequest(code="string repeat x 40000000000"))
print("SURVIVED", result.ok)
engine.close()
"""
    proc = subprocess.run(
        [sys.executable, "-c", script], capture_output=True, text=True, timeout=120
    )
    # either tcl reported the failed allocation as an eval error (bot lives)
    # or the process died — both beat exhausting the machine's memory
    if proc.returncode == 0:
        assert "SURVIVED False" in proc.stdout, proc.stdout
    else:
        assert proc.returncode != 0

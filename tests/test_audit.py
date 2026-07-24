import json

import pytest

from smeggdrop.audit import audit_state
from smeggdrop.state import FileStateStore


@pytest.fixture
def store(tmp_path):
    s = FileStateStore(tmp_path)
    s.save_many(
        "procs",
        {
            "good": "{} {return good}",
            "needs_exec": "{} {exec ls /}",
            "mystery": "{} {frobnicate 1 2}",
            "with_args": "{a b} {expr {$a + $b}}",
            "defaulted": '{{who world}} {return "hi $who"}',
            "wont_load": "{} {return {unbalanced",
        },
    )
    s.save_many("vars", {"ok_var": "scalar {1}", "bad_var": "bogus {1}"})
    return s


def by_name(report):
    return {p.name: p for p in report.procs}


def test_audit_full_report(store):
    report = audit_state(store)
    procs = by_name(report)

    assert procs["good"].loaded and procs["good"].ran and procs["good"].run_ok
    assert procs["good"].healthy

    assert "exec" in procs["needs_exec"].broken_refs
    assert procs["needs_exec"].run_ok is False
    assert not procs["needs_exec"].healthy

    assert "frobnicate" in procs["mystery"].unknown_refs
    assert procs["mystery"].run_ok is False

    # can't be called safely without args: static checks only
    assert procs["with_args"].loaded and not procs["with_args"].ran

    # all args have defaults, so it runs
    assert procs["defaulted"].ran and procs["defaulted"].run_ok

    assert not procs["wont_load"].loaded
    assert procs["wont_load"].load_error

    assert "bad_var" in report.var_load_errors
    assert "ok_var" not in report.var_load_errors


def test_audit_summary_counts(store):
    report = audit_state(store)
    summary = report.summary()
    assert summary["total"] == 6
    assert summary["load_failures"] == 1
    assert summary["broken_refs"] == 1
    assert summary["run_failures"] == 2
    assert summary["var_load_failures"] == 1


def test_audit_no_run(store):
    report = audit_state(store, run=False)
    assert not any(p.ran for p in report.procs)


def test_audit_report_is_json_serializable(store):
    json.dumps(audit_state(store).to_dict())


def test_audit_never_writes_state(store, tmp_path):
    before = {
        p.name: p.read_bytes()
        for p in tmp_path.rglob("*")
        if p.is_file()
    }
    audit_state(store)
    after = {
        p.name: p.read_bytes()
        for p in tmp_path.rglob("*")
        if p.is_file()
    }
    assert before == after

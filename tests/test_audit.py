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
            # bootstrap aliases `cache` globally after state load, hiding this
            "cache": "{} {return stale}",
            "fetches": "{} {http get http://example.com/}",
            "reads_log": "{} {llength [log]}",
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

    # shadowed by the bootstrap alias, not scanned or run, doesn't crash
    assert procs["cache"].shadowed
    assert not procs["cache"].ran

    # procs that read [log] get a plausible line, not an unset variable
    assert procs["reads_log"].ran and procs["reads_log"].run_ok

    # reached the (stubbed) network: working proc, not a failure
    assert procs["fetches"].needs_network
    assert procs["fetches"].run_ok is None
    assert procs["fetches"].healthy

    assert "bad_var" in report.var_load_errors
    assert "ok_var" not in report.var_load_errors


def test_audit_summary_counts(store):
    report = audit_state(store)
    summary = report.summary()
    assert summary["total"] == 9
    assert summary["load_failures"] == 1
    assert summary["shadowed"] == 1
    assert summary["needs_network"] == 1
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


def test_audit_calls_procs_with_arguments(store):
    # with_args covers the bulk of the library that zero-arg calls miss
    store.save_many(
        "procs",
        {
            "adds": "{a b} {expr {$a + $b}}",          # wants numbers
            "greets": "{who} {return \"hi $who\"}",     # any string works
            "broken_with_args": "{x} {exec ls $x}",     # genuinely broken
        },
    )
    report = audit_state(store, call_with_args=True)
    procs = by_name(report)

    assert procs["greets"].ran and procs["greets"].run_ok
    assert procs["greets"].arity == 1

    # "test" is not a number: that's the audit's argument being wrong, not
    # the proc being broken
    assert procs["adds"].ran and procs["adds"].arg_mismatch
    assert procs["adds"].run_ok is None

    assert procs["broken_with_args"].run_ok is False


def test_audit_without_call_with_args_skips_them(store):
    store.save_many("procs", {"greets": '{who} {return "hi $who"}'})
    procs = by_name(audit_state(store))
    assert not procs["greets"].ran
    assert procs["greets"].arity == 1

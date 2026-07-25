import pytest

from smeggdrop.engine import Engine, EvalRequest, Limits
from smeggdrop.state import FileStateStore


@pytest.fixture
def store(tmp_path):
    return FileStateStore(tmp_path)


@pytest.fixture
def engine(store):
    e = Engine(store, limits=Limits(eval_time_seconds=2))
    yield e
    e.close()


def run(engine, code, **kw):
    return engine.eval(EvalRequest(code=code, nick="tester", channel="#test", **kw))


def test_basic_eval(engine):
    result = run(engine, "expr {6 * 7}")
    assert result.ok
    assert result.output == "42"


def test_error_result(engine):
    result = run(engine, "nonexistent-command")
    assert not result.ok
    assert "nonexistent-command" in result.output


def test_procs_persist_across_engines(store, engine):
    assert run(engine, "proc triple x {expr {$x * 3}}").ok
    engine.close()

    second = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        assert run(second, "triple 5").output == "15"
    finally:
        second.close()


def test_vars_persist_and_unset_deletes(store, engine):
    assert run(engine, "set counter 41").ok
    assert run(engine, "array set prefs {color red}").ok
    assert run(engine, "incr counter").output == "42"
    engine.close()

    second = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        assert run(second, "set counter").output == "42"
        assert run(second, "set prefs(color)").output == "red"
        assert run(second, "unset counter").ok
    finally:
        second.close()

    third = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        assert not run(third, "set counter").ok
    finally:
        third.close()


def test_context_reaches_sandbox(engine):
    assert run(engine, "nick").output == "tester"
    assert run(engine, "channel").output == "#test"


def test_meta_alias_present(engine):
    # eval_count increments per eval; just needs to be an integer
    int(run(engine, "meta eval_count").output)


def test_say_callback_and_flood_cap(store):
    engine = Engine(store, limits=Limits(eval_time_seconds=2, say_max_calls=3))
    said = []
    try:
        result = engine.eval(
            EvalRequest(code="for {set i 0} {$i < 10} {incr i} {core::bot_say hi $i}"),
            say=said.append,
        )
        assert not result.ok
        assert "limit" in result.output
        assert len(said) == 3
    finally:
        engine.close()


def test_output_truncated(store):
    engine = Engine(store, limits=Limits(eval_time_seconds=2, result_max_chars=100))
    try:
        result = run(engine, "string repeat a 10000")
        assert result.ok
        assert len(result.output) < 200
        assert "truncated" in result.output
    finally:
        engine.close()


def test_runaway_eval_times_out_and_engine_survives(engine):
    result = run(engine, "while 1 {}")
    assert not result.ok
    assert run(engine, "expr {1 + 1}").output == "2"


def test_mass_change_not_persisted(store):
    engine = Engine(store, limits=Limits(eval_time_seconds=2, max_changes_per_eval=5))
    try:
        result = run(engine, "for {set i 0} {$i < 50} {incr i} {set spam_$i x}")
        assert result.ok
        assert result.warnings
    finally:
        engine.close()

    fresh = FileStateStore(store.root)
    assert fresh.load("vars") == {}


def test_unsafe_names_not_persisted(store, engine):
    result = run(engine, r'proc {bad{name} {x} {sha}} {} {return 1}')
    assert result.ok
    assert any("unsafe name" in w for w in result.warnings)
    engine.close()
    assert FileStateStore(store.root).load("procs") == {}


def test_oversized_value_not_persisted(store):
    engine = Engine(store, limits=Limits(eval_time_seconds=2, max_value_bytes=100))
    try:
        result = run(engine, "set big [string repeat a 1000]")
        assert result.ok
        assert any("too large" in w for w in result.warnings)
    finally:
        engine.close()
    assert FileStateStore(store.root).load("vars") == {}


def test_curl_call_cap(store):
    class CountingFetcher:
        calls = 0

        def fetch(self, url):
            CountingFetcher.calls += 1
            return 200, "ok"

    engine = Engine(store, limits=Limits(eval_time_seconds=2, curl_max_calls=2),
                    fetcher=CountingFetcher())
    try:
        result = run(engine, "for {set i 0} {$i < 5} {incr i} {core::curl http://example.com/}")
        assert not result.ok
        assert "limit" in result.output
        assert CountingFetcher.calls == 2
    finally:
        engine.close()


def test_legacy_state_dir_loads(tmp_path):
    import hashlib

    procs = tmp_path / "procs"
    procs.mkdir()
    sha = hashlib.sha1(b"greet").hexdigest()
    (procs / "_index").write_text("{greet} %s\n" % sha)
    (procs / sha).write_text('{name} {return "hello $name"}')
    (tmp_path / "vars").mkdir()

    engine = Engine(FileStateStore(tmp_path), limits=Limits(eval_time_seconds=2))
    try:
        assert engine.load_errors == {}
        assert run(engine, "greet world").output == "hello world"
    finally:
        engine.close()

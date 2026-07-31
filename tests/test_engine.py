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


class CountingFetcher:
    def __init__(self):
        self.calls = []

    def fetch(self, url, method="GET", body=None):
        self.calls.append((method, url, body))
        return 200, {"Content-Type": "text/plain"}, f"ok:{url}"


def test_curl_call_cap(store):
    fetcher = CountingFetcher()
    engine = Engine(store, limits=Limits(eval_time_seconds=2, curl_max_calls=2),
                    fetcher=fetcher)
    try:
        result = run(engine, "for {set i 0} {$i < 5} {incr i} {core::curl http://example.com/}")
        assert not result.ok
        assert "limit" in result.output
        assert len(fetcher.calls) == 2
    finally:
        engine.close()


def test_http_compat_from_sandbox(store):
    fetcher = CountingFetcher()
    engine = Engine(store, limits=Limits(eval_time_seconds=2), fetcher=fetcher)
    try:
        # [http get $url] -> [code {headers} body], like the tclcurl-era http.tcl
        assert run(engine, "lindex [http get http://example.com/] 0").output == "200"
        assert run(engine, "lindex [http get http://example.com/] 2").output == "ok:http://example.com/"
        # meta_proc prefix matching: "http g" resolves to get
        assert run(engine, "lindex [http g http://example.com/] 0").output == "200"

        result = run(engine, "http post http://example.com/submit q {a b} lang tcl")
        assert result.ok
        method, url, body = fetcher.calls[-1]
        assert method == "POST"
        assert body == "q=a+b&lang=tcl"

        headers = run(engine, "http head http://example.com/").output
        assert "Content-Type" in headers
    finally:
        engine.close()


def test_urlencode_builtin(engine):
    assert run(engine, "core::urlencode {a b&c}").output == "a+b%26c"


def test_tcl_automatic_error_vars_not_persisted(store, engine):
    result = run(engine, "catch {nonexistent-cmd}; set x done")
    assert result.ok
    engine.close()
    saved = FileStateStore(store.root).load("vars")
    assert "x" in saved
    assert "errorInfo" not in saved
    assert "errorCode" not in saved


def test_interp_eval_shim(engine):
    # cache::fetch runs its miss-script through interp_eval
    assert run(engine, "cache fetch b k {expr {2 + 3}}").output == "5"
    assert run(engine, "cache get b k").output == "5"


def test_loglines_reach_sandbox(engine):
    lines = ((1700000000, "alice", "alice@host", "hello there"),
             (1700000001, "bob", "bob@host", "hi alice"))
    result = engine.eval(EvalRequest(code="llength [log]", loglines=lines))
    assert result.output == "2"
    result = engine.eval(EvalRequest(code="lindex [log] 1 3", loglines=lines))
    assert result.output == "hi alice"


def test_names_and_hostmask_shims(engine):
    result = engine.eval(EvalRequest(code="names", nicks=("alice", "bob")))
    assert engine.interp.splitlist(result.output) == ("alice", "bob")

    lines = ((1700000000, "Alice", "alice!a@example.org", "yo"),)
    result = engine.eval(EvalRequest(code="hostmask alice", loglines=lines))
    assert result.output == "alice!a@example.org"
    result = engine.eval(EvalRequest(code="hostmask stranger", loglines=()))
    assert result.output == "stranger!unknown@unknown"

    # regression found live: legacy procs (remote_command_state) call this
    # bare, expecting the caller's own hostmask -- "no target" must mean
    # self, same convention as name
    lines = ((1700000000, "bob", "bob!b@example.org", "hi"),)
    result = engine.eval(EvalRequest(code="hostmask", nick="bob", loglines=lines))
    assert result.output == "bob!b@example.org"


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


def test_apply_supports_both_conventions(engine):
    # Tcl 8.5+ builtin: a lambda
    assert run(engine, "apply {{x} {expr {$x * 2}}} 21").output == "42"
    assert run(engine, "apply {{a b} {expr {$a + $b}}} 1 2").output == "3"

    # smeggdrop's older convention: a command plus an argument list, which
    # concat flattens
    assert run(engine, "apply {format %s-%s} {a b}").output == "a-b"
    assert run(engine, "apply {string toupper} {hi}").output == "HI"

    # the saved state contains procs using each, so both must work in one
    # interpreter
    assert run(engine, "proc double x {expr {$x * 2}}").ok
    assert run(engine, "apply {double} {5}").output == "10"


def test_apply_reports_real_errors(engine):
    result = run(engine, "apply {{x} {this-does-not-exist}} 1")
    assert not result.ok
    assert "this-does-not-exist" in result.output


def test_builtin_apply_stays_reachable(engine):
    # bootstrap stashes it before commands.tcl can shadow it
    assert run(engine, "tcl_apply {{x} {return $x}} ok").output == "ok"


def test_puts_no_longer_hits_missing_channel(engine):
    # a safe interp shares in no channels, so a bare [puts] used to fail
    # with "can not find channel named stdout" -- the first thing anyone
    # reaches for by ordinary tcl habit, unrelated to what they meant to do
    for code in ("puts hi", "puts stdout hi", "puts stderr hi", "puts -nonewline hi"):
        result = run(engine, code)
        assert result.ok, f"{code!r} -> {result.output}"


def test_puts_output_goes_to_the_operator_log_not_the_channel(engine, caplog):
    # matches core::print, which this is an alias for: this bot's visible
    # output has only ever been the eval's return value or core::bot_say,
    # so puts becoming non-fatal must not quietly start posting into slack
    with caplog.at_level("INFO"):
        result = run(engine, 'puts "hello there"')
    assert result.ok
    assert result.output == ""
    assert any("hello there" in r.message for r in caplog.records)


def test_puts_bogus_channel_still_errors(engine):
    result = run(engine, "puts notachannel hi")
    assert not result.ok
    assert "notachannel" in result.output


def test_puts_wrong_arg_count_still_errors(engine):
    result = run(engine, "puts a b c")
    assert not result.ok


def test_puts_works_inside_a_loop(engine):
    # the actual case that surfaced this: a proc looping over a list and
    # puts-ing each element like an ordinary tcl script would
    run(engine, "set ::items {a b c}")
    result = run(
        engine,
        "for {set i 0} {$i < [llength $::items]} {incr i} "
        '{puts "$i: [lindex $::items $i]"}',
    )
    assert result.ok


def test_reload_picks_up_externally_written_state(store, engine):
    # simulate a one-off `smeggdrop repl` fix landing on disk while the
    # engine is already running, the exact scenario hot reload is for
    other = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        run(other, "proc surprise {} {return from_outside}")
    finally:
        other.close()

    assert not run(engine, "surprise").ok  # not visible yet
    errors = engine.reload()
    assert errors == {}
    assert run(engine, "surprise").output == "from_outside"


def test_reload_preserves_engine_usability(engine):
    engine.reload()
    assert run(engine, "expr {6 * 7}").output == "42"


def test_reload_reports_load_errors(store):
    # write something that will fail to install, then confirm reload
    # surfaces it the same way startup does
    engine = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        store.save_many("procs", {"broken": "{} {unbalanced {"})
        errors = engine.reload()
        assert any("broken" in k for k in errors)
        assert engine.load_errors == errors
    finally:
        engine.close()


def test_reload_does_not_affect_concurrent_eval_ordering(store):
    # a slow eval and a reload issued back-to-back must not interleave —
    # reload only ever sees the interpreter in a consistent pre- or
    # post-eval state, never mid-eval
    engine = Engine(store, limits=Limits(eval_time_seconds=2))
    try:
        import threading

        results = []

        def slow_eval():
            results.append(("eval", run(engine, "after 200; expr {1 + 1}").output))

        t = threading.Thread(target=slow_eval)
        t.start()
        errors = engine.reload()
        t.join()

        assert errors == {}
        assert results == [("eval", "2")]
    finally:
        engine.close()

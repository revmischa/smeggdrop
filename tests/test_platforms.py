import re

from smeggdrop.platforms import DEFAULT_TRIGGER, ChatLog, chunk_output, extract_code


def test_chat_log_accumulates_and_slurps():
    log = ChatLog(max_lines=3)
    for i in range(5):
        log.append("#chan", f"nick{i}", None, f"msg {i}")
    log.append("#other", "x", "x@y", "elsewhere")

    lines = log.slurp("#chan")
    assert [l[3] for l in lines] == ["msg 2", "msg 3", "msg 4"]  # bounded
    assert all(len(l) == 4 for l in lines)
    assert log.slurp("#chan") == ()  # drained
    assert log.slurp("#other")[0][1] == "x"  # channels are independent


def test_extract_code_default_trigger():
    assert extract_code("tcl expr {1 + 1}") == "expr {1 + 1}"
    assert extract_code("  tcl set x 1") == "set x 1"
    assert extract_code("nothing to see") is None
    assert extract_code("tclnope") is None


def test_extract_code_custom_trigger():
    trigger = re.compile(r"^!eval\s+")
    assert extract_code("!eval puts hi", trigger) == "puts hi"
    assert extract_code("tcl puts hi", trigger) is None


def test_chunk_output_splits_long_lines():
    chunks = chunk_output("a" * 25, max_chunk=10, max_chunks=20)
    assert chunks == ["a" * 10, "a" * 10, "a" * 5]


def test_chunk_output_caps_total_chunks():
    text = "\n".join(str(i) for i in range(100))
    chunks = chunk_output(text, max_chunk=100, max_chunks=5)
    assert len(chunks) == 5
    assert "truncated" in chunks[-1]


def test_default_trigger_matches_perl_config():
    assert DEFAULT_TRIGGER.pattern == r"^\s*tcl\s"


def test_trigger_is_case_insensitive():
    # phone keyboards autocapitalize the first word of a message
    assert extract_code("Tcl expr {1 + 1}") == "expr {1 + 1}"
    assert extract_code("TCL expr {1 + 1}") == "expr {1 + 1}"
    assert extract_code("  TcL set x 1") == "set x 1"
    # still anchored: a mention of tcl mid-sentence is not a trigger
    assert extract_code("I love Tcl actually") is None

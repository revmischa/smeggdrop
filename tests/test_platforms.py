import re

from smeggdrop.platforms import DEFAULT_TRIGGER, chunk_output, extract_code


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

import hashlib

from smeggdrop.state import FileStateStore, name_sha1


def test_roundtrip(tmp_path):
    store = FileStateStore(tmp_path)
    store.save_many("procs", {"greet": "{name} {return hi}"})
    store.save_many("vars", {"x": "scalar {1}"})

    fresh = FileStateStore(tmp_path)
    assert fresh.load("procs") == {"greet": "{name} {return hi}"}
    assert fresh.load("vars") == {"x": "scalar {1}"}


def test_legacy_perl_layout_loads(tmp_path):
    # exactly what the perl bot writes: {name} sha1 per index line,
    # sha1-of-name data files
    procs = tmp_path / "procs"
    procs.mkdir(parents=True)
    name = "greet"
    sha = hashlib.sha1(name.encode()).hexdigest()
    (procs / "_index").write_text("{%s} %s\n" % (name, sha))
    (procs / sha).write_text('{name} {return "hello $name"}')
    (tmp_path / "vars").mkdir()

    store = FileStateStore(tmp_path)
    assert store.load("procs") == {name: '{name} {return "hello $name"}'}


def test_deletion_writes_empty_file_and_skips_on_load(tmp_path):
    store = FileStateStore(tmp_path)
    store.save_many("vars", {"x": "scalar {1}", "keep": "scalar {2}"})
    store.save_many("vars", {"x": None})

    sha = name_sha1("x")
    assert (tmp_path / "vars" / sha).read_text() == ""
    fresh = FileStateStore(tmp_path)
    assert fresh.load("vars") == {"keep": "scalar {2}"}
    # loader cleans up the marker file like the perl one did, and prunes
    # the index entry so deletions don't accumulate
    assert not (tmp_path / "vars" / sha).exists()
    assert "{x}" not in (tmp_path / "vars" / "_index").read_text()

    # a save after the pruned load must not resurrect the entry
    fresh.save_many("vars", {"other": "scalar {3}"})
    third = FileStateStore(tmp_path)
    assert third.load("vars") == {"keep": "scalar {2}", "other": "scalar {3}"}


def test_missing_data_file_keeps_index_entry(tmp_path):
    # damage (file gone, no deletion marker) must stay visible, not be pruned
    store = FileStateStore(tmp_path)
    store.save_many("procs", {"lost": "{} {return x}"})
    (tmp_path / "procs" / name_sha1("lost")).unlink()

    fresh = FileStateStore(tmp_path)
    assert fresh.load("procs") == {}
    assert "{lost}" in (tmp_path / "procs" / "_index").read_text()


def test_malformed_index_lines_skipped(tmp_path):
    vars_dir = tmp_path / "vars"
    vars_dir.mkdir(parents=True)
    sha = name_sha1("ok")
    (vars_dir / "_index").write_text(
        "garbage with several words here\n{ok} %s\n\n" % sha
    )
    (vars_dir / sha).write_text("scalar {fine}")
    store = FileStateStore(tmp_path)
    assert store.load("vars") == {"ok": "scalar {fine}"}


def test_names_never_become_paths(tmp_path):
    store = FileStateStore(tmp_path)
    evil = "../../escape"
    store.save_many("procs", {evil: "{} {return x}"})
    # data lands under procs/ named by sha1, not by the name
    assert (tmp_path / "procs" / name_sha1(evil)).exists()
    assert not (tmp_path.parent / "escape").exists()
    assert FileStateStore(tmp_path).load("procs") == {evil: "{} {return x}"}


def test_open_store_dispatches_on_location(tmp_path, monkeypatch):
    from smeggdrop.state import FileStateStore as FSS
    from smeggdrop.state import open_store

    assert isinstance(open_store(str(tmp_path)), FSS)

    # s3 uris get the s3 store, without needing credentials to construct
    import smeggdrop.state_s3 as state_s3

    monkeypatch.setattr(state_s3.S3StateStore, "client", property(lambda self: None))
    store = open_store("s3://bucket/prefix")
    assert isinstance(store, state_s3.S3StateStore)
    assert store.bucket == "bucket"


def test_legacy_latin1_bytes_survive_loading(tmp_path):
    # the perl bot used `use bytes`, so some procs hold latin-1 art:
    # ¯`·.¸¸.·´¯ waves and °_o faces. errors="replace" destroyed them.
    from smeggdrop.state import decode

    procs = tmp_path / "procs"
    procs.mkdir(parents=True)
    (tmp_path / "vars").mkdir()
    raw = b'{} { return "\xb0_o \xb7_. \xaf`\xb7.\xb8\xb8.\xb7\xb4\xaf" }'
    sha = name_sha1("face")
    (procs / "_index").write_text("{face} %s\n" % sha)
    (procs / sha).write_bytes(raw)

    loaded = FileStateStore(tmp_path).load("procs")["face"]
    assert "�" not in loaded
    assert "°_o" in loaded and "·_." in loaded
    assert "¯`·.¸¸.·´¯" in loaded

    # utf-8 content still decodes as utf-8, not mojibake
    assert decode("✗ ünïcode".encode("utf-8")) == "✗ ünïcode"

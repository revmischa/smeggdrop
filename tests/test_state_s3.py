"""S3 state store, exercised against a fake S3 that mimics the parts we use:
ETags, conditional writes, and NoSuchKey."""

import json

import pytest

from smeggdrop.state_s3 import S3StateStore


class FakeS3:
    """Minimal S3: objects with ETags and If-Match/If-None-Match semantics."""

    def __init__(self):
        self.objects: dict[tuple[str, str], bytes] = {}
        self.etags: dict[tuple[str, str], str] = {}
        self.puts = 0
        self._counter = 0

    def get_object(self, *, Bucket, Key):
        item = (Bucket, Key)
        if item not in self.objects:
            raise ClientError("NoSuchKey")
        return {"Body": Body(self.objects[item]), "ETag": self.etags[item]}

    def put_object(self, *, Bucket, Key, Body, ContentType=None, IfMatch=None, IfNoneMatch=None):
        self.puts += 1
        item = (Bucket, Key)
        current = self.etags.get(item)
        if IfMatch is not None and current != IfMatch:
            raise ClientError("PreconditionFailed")
        if IfNoneMatch == "*" and item in self.objects:
            raise ClientError("PreconditionFailed")
        self._counter += 1
        etag = f'"etag-{self._counter}"'
        self.objects[item] = Body
        self.etags[item] = etag
        return {"ETag": etag}

    def contents(self, bucket, key):
        return json.loads(self.objects[(bucket, key)].decode())


class Body:
    def __init__(self, data):
        self.data = data

    def read(self):
        return self.data


class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


@pytest.fixture
def s3():
    return FakeS3()


@pytest.fixture
def store(s3):
    return S3StateStore("bucket", "smeggdrop/state", client=s3)


def test_from_uri():
    store = S3StateStore.from_uri("s3://my-bucket/some/prefix", client=object())
    assert store.bucket == "my-bucket"
    assert store.prefix == "some/prefix"
    assert store.key("procs") == "some/prefix/procs.json"

    bare = S3StateStore.from_uri("s3://my-bucket", client=object())
    assert bare.key("vars") == "vars.json"

    with pytest.raises(ValueError):
        S3StateStore.from_uri("/not/s3", client=object())


def test_missing_state_loads_empty(store):
    assert store.load("procs") == {}


def test_roundtrip(store, s3):
    store.load("procs")
    store.save_many("procs", {"greet": "{} {return hi}"})
    assert s3.contents("bucket", "smeggdrop/state/procs.json") == {"greet": "{} {return hi}"}

    fresh = S3StateStore("bucket", "smeggdrop/state", client=s3)
    assert fresh.load("procs") == {"greet": "{} {return hi}"}


def test_deletions_remove_keys(store, s3):
    store.load("vars")
    store.save_many("vars", {"x": "scalar {1}", "y": "scalar {2}"})
    store.save_many("vars", {"x": None})
    assert store.load("vars") == {"y": "scalar {2}"}


def test_one_put_per_save_not_per_entry(store, s3):
    store.load("procs")
    store.save_many("procs", {f"p{i}": "{} {return x}" for i in range(50)})
    assert s3.puts == 1  # the whole point: not 50 round trips


def test_empty_changes_skip_the_write(store, s3):
    store.load("procs")
    store.save_many("procs", {})
    assert s3.puts == 0


def test_concurrent_writer_is_merged_not_clobbered(store, s3):
    store.load("procs")
    store.save_many("procs", {"mine": "{} {return mine}"})

    # another container defines a different proc against the same state
    other = S3StateStore("bucket", "smeggdrop/state", client=s3)
    other.load("procs")
    other.save_many("procs", {"theirs": "{} {return theirs}"})

    # our next write must not drop theirs
    store.save_many("procs", {"mine2": "{} {return mine2}"})
    final = s3.contents("bucket", "smeggdrop/state/procs.json")
    assert set(final) == {"mine", "theirs", "mine2"}


def test_create_is_conditional(store, s3):
    # a store that never loaded must not blow away an existing object
    s3.put_object(
        Bucket="bucket",
        Key="smeggdrop/state/procs.json",
        Body=json.dumps({"existing": "{} {return e}"}).encode(),
    )
    fresh = S3StateStore("bucket", "smeggdrop/state", client=s3)
    fresh.save_many("procs", {"new": "{} {return n}"})
    final = s3.contents("bucket", "smeggdrop/state/procs.json")
    assert set(final) == {"existing", "new"}


def test_unicode_survives(store, s3):
    store.load("vars")
    store.save_many("vars", {"emoji": "scalar {✗ ünïcode}"})
    assert S3StateStore("bucket", "smeggdrop/state", client=s3).load("vars") == {
        "emoji": "scalar {✗ ünïcode}"
    }

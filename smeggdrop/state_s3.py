"""S3-backed state, for running on Lambda.

The file layout stores one object per proc, which is fine on a disk and
terrible against an object store: 6,600 GETs on every cold start. The whole
hardchats state is only ~6 MB of actual content, so each category is packed
into a single JSON object instead — one GET to load, one PUT per eval that
changes anything.

History comes from S3 bucket versioning rather than from keeping old
objects around: turn it on and every eval's state becomes a restorable
version.

Concurrent writers are handled with a conditional PUT (If-Match on the
ETag we loaded). If another process wrote in between, this reloads, re-
applies its own changes on top, and retries — so a second Lambda container
can't silently clobber a proc someone just defined. Run with reserved
concurrency 1 anyway; this is the backstop, not the plan.
"""

from __future__ import annotations

import json
import logging
from typing import Mapping

log = logging.getLogger(__name__)

CATEGORIES = ("procs", "vars")
PUT_ATTEMPTS = 5


class S3StateStore:
    def __init__(self, bucket: str, prefix: str = "", client=None):
        self.bucket = bucket
        self.prefix = prefix.strip("/")
        self._client = client
        self._snapshots: dict[str, dict[str, str]] = {}
        self._etags: dict[str, str | None] = {}

    @classmethod
    def from_uri(cls, uri: str, client=None) -> "S3StateStore":
        """s3://bucket/optional/prefix"""
        if not uri.startswith("s3://"):
            raise ValueError(f"not an s3 uri: {uri!r}")
        bucket, _, prefix = uri[len("s3://") :].partition("/")
        if not bucket:
            raise ValueError(f"no bucket in {uri!r}")
        return cls(bucket, prefix, client=client)

    @property
    def client(self):
        if self._client is None:
            import boto3  # imported lazily so the core stays dependency-free

            self._client = boto3.client("s3")
        return self._client

    def key(self, category: str) -> str:
        return f"{self.prefix}/{category}.json" if self.prefix else f"{category}.json"

    # -- StateStore protocol -------------------------------------------

    def load(self, category: str) -> dict[str, str]:
        snapshot, etag = self._fetch(category)
        self._snapshots[category] = snapshot
        self._etags[category] = etag
        return dict(snapshot)

    def save_many(self, category: str, changes: Mapping[str, str | None]) -> None:
        if not changes:
            return
        for attempt in range(1, PUT_ATTEMPTS + 1):
            snapshot = dict(self._snapshots.get(category, {}))
            _apply(snapshot, changes)
            try:
                etag = self._put(category, snapshot, self._etags.get(category))
            except _Conflict:
                # somebody else wrote; take their version and re-apply ours
                log.warning("%s: state changed underneath us, merging", category)
                fresh, fresh_etag = self._fetch(category)
                self._snapshots[category] = fresh
                self._etags[category] = fresh_etag
                if attempt == PUT_ATTEMPTS:
                    raise
                continue
            self._snapshots[category] = snapshot
            self._etags[category] = etag
            return

    # -- s3 plumbing ----------------------------------------------------

    def _fetch(self, category: str) -> tuple[dict[str, str], str | None]:
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=self.key(category))
        except Exception as e:  # noqa: BLE001 — botocore raises dynamic classes
            if _is_missing(e):
                return {}, None
            raise
        body = response["Body"].read()
        etag = response.get("ETag")
        if not body:
            return {}, etag
        return json.loads(body.decode("utf-8")), etag

    def _put(self, category: str, snapshot: dict[str, str], etag: str | None) -> str | None:
        body = json.dumps(snapshot, ensure_ascii=False, sort_keys=True).encode("utf-8")
        kwargs = {
            "Bucket": self.bucket,
            "Key": self.key(category),
            "Body": body,
            "ContentType": "application/json",
        }
        conditional = dict(kwargs)
        if etag:
            conditional["IfMatch"] = etag
        else:
            conditional["IfNoneMatch"] = "*"  # create-only, don't clobber
        try:
            response = self.client.put_object(**conditional)
        except Exception as e:  # noqa: BLE001
            if _is_precondition_failed(e):
                raise _Conflict from e
            if not _is_unsupported_parameter(e):
                raise
            # older botocore, or a store without conditional writes: fall
            # back to an unconditional put and rely on single-writer
            log.warning("conditional put unsupported; writing unconditionally")
            response = self.client.put_object(**kwargs)
        return response.get("ETag")


class _Conflict(Exception):
    pass


def _apply(snapshot: dict[str, str], changes: Mapping[str, str | None]) -> None:
    for name, value in changes.items():
        if value is None:
            snapshot.pop(name, None)
        else:
            snapshot[name] = value


def _error_code(error: Exception) -> str:
    response = getattr(error, "response", None) or {}
    return str(response.get("Error", {}).get("Code", ""))


def _is_missing(error: Exception) -> bool:
    return _error_code(error) in ("NoSuchKey", "404", "NotFound")


def _is_precondition_failed(error: Exception) -> bool:
    return _error_code(error) in ("PreconditionFailed", "412", "ConditionalRequestConflict")


def _is_unsupported_parameter(error: Exception) -> bool:
    name = type(error).__name__
    return name in ("ParamValidationError", "ClientError") and "IfMatch" in str(error)

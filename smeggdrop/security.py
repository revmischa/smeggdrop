"""Outbound HTTP for sandboxed code, with SSRF protections.

Everything a user types in chat can reach core::curl, so the fetcher
refuses anything that isn't plain http(s) to a public address:

- scheme allowlist (http, https), no userinfo in URLs
- every hostname is resolved and all addresses must be globally routable —
  no loopback, RFC1918, link-local (cloud metadata), CGNAT, multicast, etc.
- redirects are followed manually and every hop is re-validated
- response bodies are size-capped, requests time-limited

Known gap: we validate at lookup time and urllib re-resolves to connect, so
a DNS server flipping records between the two lookups (rebinding) could
still reach an internal address. Run the bot somewhere with no interesting
internal network (a Lambda outside any VPC is exactly that) and this is
moot; defense in depth, not a substitute for network isolation.
"""

from __future__ import annotations

import ipaddress
import socket
import urllib.error
import urllib.request
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit

USER_AGENT = "smeggdrop/2 (+https://github.com/revmischa/smeggdrop)"
REDIRECT_CODES = {301, 302, 303, 307, 308}


class FetchError(Exception):
    pass


@dataclass(frozen=True)
class FetchPolicy:
    timeout: float = 10.0
    max_bytes: int = 1_000_000
    max_post_bytes: int = 150_000  # same default the old http.tcl enforced
    max_redirects: int = 3
    allowed_schemes: frozenset[str] = frozenset({"http", "https"})
    # tests and local dev only; never enable where an internal network exists
    allow_private: bool = False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SafeFetcher:
    def __init__(self, policy: FetchPolicy | None = None):
        self.policy = policy or FetchPolicy()
        self._opener = urllib.request.build_opener(_NoRedirect())

    def fetch(
        self, url: str, method: str = "GET", body: str | None = None
    ) -> tuple[int, dict[str, str], str]:
        """Request a URL. Returns (status, headers, body). Raises FetchError
        on refusal. Only GET/HEAD/POST; POST bodies are size-capped."""
        method = method.upper()
        if method not in ("GET", "HEAD", "POST"):
            raise FetchError(f"refusing method {method!r}")
        data = None
        if method == "POST":
            data = (body or "").encode("utf-8")
            if len(data) > self.policy.max_post_bytes:
                raise FetchError(f"post body exceeds {self.policy.max_post_bytes} bytes")
        for _ in range(self.policy.max_redirects + 1):
            self.validate(url)
            req = urllib.request.Request(
                url, data=data, headers={"User-Agent": USER_AGENT}, method=method
            )
            try:
                resp = self._opener.open(req, timeout=self.policy.timeout)
            except urllib.error.HTTPError as e:
                resp = e  # HTTPError is a usable response object
            except (urllib.error.URLError, OSError) as e:
                raise FetchError(f"fetch failed: {getattr(e, 'reason', e)}") from e
            with resp:
                status = resp.status if resp.status is not None else 0
                headers = dict(resp.headers.items())
                if status in REDIRECT_CODES:
                    location = resp.headers.get("Location")
                    if not location:
                        return status, headers, ""
                    url = urljoin(url, location)
                    if status == 303:
                        method, data = "GET", None
                    continue
                raw = resp.read(self.policy.max_bytes + 1)
            if len(raw) > self.policy.max_bytes:
                raw = raw[: self.policy.max_bytes]
            return status, headers, raw.decode("utf-8", "replace")
        raise FetchError(f"too many redirects (>{self.policy.max_redirects})")

    def validate(self, url: str) -> None:
        try:
            parts = urlsplit(url)
        except ValueError as e:
            raise FetchError(f"unparseable url: {e}") from e
        if parts.scheme.lower() not in self.policy.allowed_schemes:
            raise FetchError(f"refusing scheme {parts.scheme!r}")
        if parts.username or parts.password:
            raise FetchError("refusing url with credentials")
        host = parts.hostname
        if not host:
            raise FetchError("no hostname in url")
        try:
            port = parts.port
        except ValueError as e:
            raise FetchError(f"bad port: {e}") from e
        port = port or (443 if parts.scheme == "https" else 80)
        if self.policy.allow_private:
            return
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except socket.gaierror as e:
            raise FetchError(f"cannot resolve {host!r}: {e}") from e
        for info in infos:
            addr = ipaddress.ip_address(info[4][0])
            if not addr.is_global or addr.is_multicast:
                raise FetchError(f"refusing non-public address for {host!r}")

import http.server
import threading

import pytest

from smeggdrop.security import FetchError, FetchPolicy, SafeFetcher


@pytest.mark.parametrize(
    "url",
    [
        "ftp://example.com/file",
        "file:///etc/passwd",
        "gopher://example.com/",
        "http://user:pass@example.com/",
        "http://127.0.0.1/",
        "http://[::1]/",
        "http://10.0.0.1/",
        "http://192.168.1.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://100.64.0.1/",
        "http://0.0.0.0/",
        "http://localhost/",
    ],
)
def test_validate_refuses(url):
    with pytest.raises(FetchError):
        SafeFetcher().validate(url)


def test_validate_allows_public_literal():
    SafeFetcher().validate("http://8.8.8.8/")
    SafeFetcher().validate("https://1.1.1.1/x?y=z")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        reply = b"posted:" + body
        self.send_response(200)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("X-Smeg", "yes")
        self.end_headers()

    def do_GET(self):
        if self.path == "/hello":
            body = b"hello world"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/hello")
            self.end_headers()
        elif self.path == "/loop":
            self.send_response(302)
            self.send_header("Location", "/loop")
            self.end_headers()
        elif self.path == "/big":
            body = b"x" * 5000
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def server():
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()


@pytest.fixture
def fetcher():
    # allow_private so tests can hit the local server; production default is off
    return SafeFetcher(
        FetchPolicy(
            allow_private=True, max_bytes=1000, max_post_bytes=1000, max_redirects=2, timeout=5
        )
    )


def test_fetch_ok(server, fetcher):
    status, headers, body = fetcher.fetch(server + "/hello")
    assert status == 200
    assert body == "hello world"
    assert headers.get("Content-Length") == str(len("hello world"))


def test_fetch_follows_redirect(server, fetcher):
    status, _, body = fetcher.fetch(server + "/redirect")
    assert status == 200
    assert body == "hello world"


def test_fetch_redirect_loop_capped(server, fetcher):
    with pytest.raises(FetchError, match="redirect"):
        fetcher.fetch(server + "/loop")


def test_fetch_body_capped(server, fetcher):
    status, _, body = fetcher.fetch(server + "/big")
    assert status == 200
    assert len(body) == 1000


def test_fetch_non_2xx_returned_not_raised(server, fetcher):
    status, _, _ = fetcher.fetch(server + "/nope")
    assert status == 404


def test_fetch_post(server, fetcher):
    status, _, body = fetcher.fetch(server + "/echo", method="POST", body="a=1&b=2")
    assert status == 200
    assert body == "posted:a=1&b=2"


def test_fetch_head(server, fetcher):
    status, headers, body = fetcher.fetch(server + "/hello", method="HEAD")
    assert status == 200
    assert headers.get("X-Smeg") == "yes"
    assert body == ""


def test_post_body_capped(server, fetcher):
    with pytest.raises(FetchError, match="post body"):
        fetcher.fetch(server + "/echo", method="POST", body="x" * 5000)


def test_unsupported_method_refused(fetcher):
    with pytest.raises(FetchError, match="method"):
        fetcher.fetch("http://example.com/", method="DELETE")

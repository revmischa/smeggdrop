"""Does the bolt app actually invoke the handler, for real requests?

A total failure to respond got past the rest of the suite and only turned
up against a live workspace: every other test calls handle_message_event
directly, so nothing covered the middleware or the listener registration.

The bug was the retry-dropping middleware testing for the *presence* of
x-slack-retry-num. Slack sets that header on first delivery too, valued 0,
so every message was silently discarded — acked in 0ms with nothing logged.

(A lazy-listener theory was investigated and disproved along the way:
`test_lazy_wiring_also_runs` pins the actual behaviour, which is that bolt
runs lazy listeners outside FaaS too, via its thread pool.)

These drive real BoltRequests through app.dispatch().
"""

import json
import time

import pytest

from smeggdrop.engine import Engine, Limits
from smeggdrop.platforms.slack import SlackConfig, build_app
from smeggdrop.state import FileStateStore

pytest.importorskip("slack_bolt")

from slack_sdk.web import WebClient  # noqa: E402  (must follow importorskip)


@pytest.fixture
def posted(monkeypatch):
    """Capture outbound api calls at the class level.

    Bolt constructs its own WebClient per request from the authorize
    result, so patching an instance handed to build_app would be ignored.
    """
    sent: list[tuple[str, str]] = []

    def chat_postMessage(self, *, channel, text=None, **kwargs):
        sent.append((channel, text))
        return {"ok": True, "ts": "1.0"}

    def users_info(self, *, user, **kwargs):
        return {"user": {"name": "alice", "profile": {}}}

    def conversations_info(self, *, channel, **kwargs):
        return {"channel": {"name": "tcl"}}

    monkeypatch.setattr(WebClient, "chat_postMessage", chat_postMessage)
    monkeypatch.setattr(WebClient, "users_info", users_info)
    monkeypatch.setattr(WebClient, "conversations_info", conversations_info)
    return sent


def fake_authorize(**kwargs):
    """Avoid bolt's auth.test round trip to slack."""
    from slack_bolt.authorization import AuthorizeResult

    return AuthorizeResult(
        enterprise_id=None,
        team_id="T1",
        bot_token="xoxb-test",
        bot_id="BBOT",
        bot_user_id="UBOT",
    )


def event_request(text, channel="C123", retry_num="0", event_id="Ev1", lazy_only=False):
    from slack_bolt.request import BoltRequest

    body = {
        "team_id": "T1",
        "api_app_id": "A1",
        "type": "event_callback",
        "event_id": event_id,
        "event_time": 1,
        "event": {
            "type": "message",
            "channel": channel,
            "user": "U1",
            "text": text,
            "ts": "1.0",
        },
    }
    headers = {"content-type": ["application/json"]}
    if retry_num is not None:
        headers["x-slack-retry-num"] = [retry_num]
    if lazy_only:
        # what bolt's lambda lazy runner adds when it re-invokes the function;
        # the name picks which registered lazy listener to run
        headers["x-slack-bolt-lazy-only"] = ["1"]
        headers["x-slack-bolt-lazy-function-name"] = ["evaluate"]
    return BoltRequest(body=json.dumps(body), headers=headers, mode="socket_mode")


def wait_for(sent, count, timeout=15.0):
    """Non-lazy listeners run in bolt's thread pool, so dispatch returns
    before the eval finishes."""
    deadline = time.time() + timeout
    while time.time() < deadline and len(sent) < count:
        time.sleep(0.05)
    return sent


def settle(seconds=1.5):
    """Give a listener thread time to run when expecting no output."""
    time.sleep(seconds)


def make_app(engine, **kwargs):
    return build_app(
        engine,
        SlackConfig(channels=frozenset({"C123"})),
        signing_secret="secret",
        request_verification_enabled=False,
        authorize=fake_authorize,
        **kwargs,
    )


@pytest.fixture
def engine(tmp_path):
    e = Engine(FileStateStore(tmp_path), limits=Limits(eval_time_seconds=3))
    yield e
    e.close()


def test_socket_mode_wiring_runs_the_eval(engine, posted):
    app = make_app(engine)
    response = app.dispatch(event_request("tcl expr {40 + 2}"))
    assert response.status == 200
    assert wait_for(posted, 1) == [("C123", "```42```")]


def test_first_delivery_is_not_treated_as_a_retry(engine, posted):
    app = make_app(engine)
    app.dispatch(event_request("tcl expr {1 + 1}", retry_num="0"))
    assert wait_for(posted, 1) == [("C123", "```2```")]


def test_missing_retry_header_is_fine(engine, posted):
    app = make_app(engine)
    app.dispatch(event_request("tcl expr {1 + 1}", retry_num=None))
    assert wait_for(posted, 1) == [("C123", "```2```")]


def test_duplicate_delivery_runs_once(engine, posted):
    app = make_app(engine)
    app.dispatch(event_request("tcl expr {1 + 1}", event_id="EvDup"))
    assert wait_for(posted, 1) == [("C123", "```2```")]
    # slack redelivering the same event must not re-run it
    app.dispatch(event_request("tcl expr {1 + 1}", retry_num="1", event_id="EvDup"))
    settle()
    assert len(posted) == 1


def test_lazy_reinvocation_is_not_deduped(engine, posted):
    # On lambda one event is two invocations of the same function: the first
    # acks, then bolt invokes again to run the eval, reusing the event id the
    # ack already claimed. That second call frequently lands on the same warm
    # container, so deduping it drops the eval and the bot acks everything and
    # answers nothing. Observed against the deployed function before the fix.
    app = make_app(engine, lazy=True)
    app.dispatch(event_request("tcl expr {1 + 1}", event_id="EvLazy"))
    assert wait_for(posted, 1) == [("C123", "```2```")]

    app.dispatch(event_request("tcl expr {1 + 1}", event_id="EvLazy", lazy_only=True))
    assert wait_for(posted, 2) == [("C123", "```2```"), ("C123", "```2```")]


def test_retry_of_an_unseen_event_still_runs(engine, posted):
    # the case that was silently losing messages: the first delivery went
    # unacked (bot restarting), so the retry is the only chance to run it
    app = make_app(engine)
    app.dispatch(event_request("tcl expr {1 + 1}", retry_num="1", event_id="EvMissed"))
    assert wait_for(posted, 1) == [("C123", "```2```")]


def test_non_triggers_are_ignored(engine, posted):
    app = make_app(engine)
    app.dispatch(event_request("just chatting about tcl"))
    settle()
    assert posted == []


def test_other_channels_are_ignored(engine, posted):
    app = make_app(engine)
    app.dispatch(event_request("tcl expr {1 + 1}", channel="COTHER"))
    settle()
    assert posted == []


def test_lazy_wiring_also_runs(engine, posted):
    # The FaaS shape acks first and defers the eval. Outside a FaaS adapter
    # bolt still runs lazy listeners, in its thread pool, rather than
    # dropping them — so this must not be asserted as "posts nothing".
    # Pinning it because the opposite was assumed while debugging.
    app = make_app(engine, lazy=True)
    response = app.dispatch(event_request("tcl expr {40 + 2}"))
    assert response.status == 200
    assert wait_for(posted, 1) == [("C123", "```42```")]

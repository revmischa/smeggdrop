# tests for the slack adapter's decision logic; no slack sdk required —
# the client is duck-typed and bolt is only imported inside build_app()

import pytest

from smeggdrop.engine import Engine, Limits
from smeggdrop.platforms.slack import (
    NickCache,
    SlackConfig,
    format_reply,
    handle_message_event,
    strip_irc_formatting,
    unfuck_slack_message,
)
from smeggdrop.state import FileStateStore


class StubClient:
    def __init__(self, user_names=None, channel_names=None):
        self.posted = []
        self.user_names = user_names or {}
        self.channel_names = channel_names if channel_names is not None else {"C123": "tcl"}

    def chat_postMessage(self, *, channel, text, **kwargs):
        self.posted.append((channel, text))

    def users_info(self, *, user):
        if user not in self.user_names:
            raise RuntimeError("user_not_found")
        return {"user": {"name": self.user_names[user], "profile": {}}}

    def conversations_info(self, *, channel):
        if channel not in self.channel_names:
            raise RuntimeError("channel_not_found")
        return {"channel": {"name": self.channel_names[channel]}}


@pytest.fixture
def engine(tmp_path):
    e = Engine(FileStateStore(tmp_path), limits=Limits(eval_time_seconds=2))
    yield e
    e.close()


@pytest.fixture
def cfg():
    return SlackConfig()


def event(text, **kw):
    return {"type": "message", "channel": "C123", "user": "U1", "text": text, **kw}


def test_trigger_evaluates_and_replies(engine, cfg):
    client = StubClient(user_names={"U1": "alice"})
    assert handle_message_event(engine, client, event("tcl expr {6 * 7}"), cfg)
    assert client.posted == [("C123", "```42```")]


def test_non_trigger_ignored(engine, cfg):
    client = StubClient()
    assert not handle_message_event(engine, client, event("just chatting about tcl"), cfg)
    assert client.posted == []


def test_bot_messages_never_evaluated(engine, cfg):
    client = StubClient()
    assert not handle_message_event(
        engine, client, event("tcl expr 1", bot_id="B999"), cfg
    )
    assert not handle_message_event(
        engine, client, event("tcl expr 1", subtype="bot_message"), cfg
    )
    assert client.posted == []


def test_edited_message_evaluated(engine, cfg):
    client = StubClient()
    evt = {
        "type": "message",
        "subtype": "message_changed",
        "channel": "C123",
        "message": {"user": "U1", "text": "tcl expr {1 + 1}"},
    }
    assert handle_message_event(engine, client, evt, cfg)
    assert client.posted == [("C123", "```2```")]


def test_channel_allowlist(engine):
    cfg = SlackConfig(channels=frozenset({"CALLOWED"}))
    client = StubClient()
    assert not handle_message_event(engine, client, event("tcl expr 1"), cfg)
    assert client.posted == []


def test_nick_reaches_sandbox(engine, cfg):
    client = StubClient(user_names={"U1": "alice"})
    handle_message_event(engine, client, event("tcl nick"), cfg)
    assert client.posted == [("C123", "```alice```")]


def test_nick_falls_back_to_id(engine, cfg):
    client = StubClient()  # users_info fails
    handle_message_event(engine, client, event("tcl nick"), cfg)
    assert client.posted == [("C123", "```U1```")]


def test_say_posts_immediately(engine, cfg):
    client = StubClient()
    handle_message_event(engine, client, event("tcl core::bot_say hi there"), cfg)
    assert client.posted[0] == ("C123", "hi there")


def test_error_reply(engine, cfg):
    client = StubClient()
    handle_message_event(engine, client, event("tcl no-such-command"), cfg)
    assert len(client.posted) == 1
    assert client.posted[0][1].startswith("```error:")


def test_slack_mangled_url_unwrapped(engine, cfg):
    client = StubClient()
    handle_message_event(
        engine, client, event("tcl string length <http://x.io/a?b=1|x.io/a?b=1>"), cfg
    )
    assert client.posted == [("C123", "```%d```" % len("http://x.io/a?b=1"))]


@pytest.mark.parametrize(
    "mangled,clean",
    [
        ("<http://example.com|example.com>", "http://example.com"),
        ("<https://example.com/x>", "https://example.com/x"),
        ("`tcl expr 1`", "tcl expr 1"),
        ("a &amp; b &lt;c&gt;", "a & b <c>"),
        ("plain text", "plain text"),
    ],
)
def test_unfuck_slack_message(mangled, clean):
    assert unfuck_slack_message(mangled) == clean


def test_format_reply_fences_and_truncates():
    messages = format_reply(True, "x" * 20000, [])
    assert all(m.startswith("```") and m.endswith("```") for m in messages)
    assert len(messages) <= 3
    assert "(truncated)" in messages[-1]


def test_format_reply_escapes_fences_and_warnings():
    (message,) = format_reply(True, "a```b", ["heads up"])
    assert "'''" in message
    assert "warning: heads up" in message


def test_format_reply_empty_output():
    assert format_reply(True, "", []) == ["```(no output)```"]


def test_config_from_env():
    cfg = SlackConfig.from_env(
        {
            "SMEGGDROP_TRIGGER": r"^!eval\s",
            "SMEGGDROP_CHANNELS": "C1, C2 ,",
            "SMEGGDROP_STATE": "/data/state",
            "SMEGGDROP_TIME_LIMIT": "3",
            "SLACK_APP_TOKEN": "xapp-1",
        }
    )
    assert cfg.trigger.pattern == r"^!eval\s"
    assert cfg.channels == frozenset({"C1", "C2"})
    assert cfg.state_dir == "/data/state"
    assert cfg.time_limit == 3
    assert cfg.app_token == "xapp-1"


def test_chat_log_feeds_eval_and_drains(engine, cfg):
    from smeggdrop.platforms import ChatLog

    client = StubClient(user_names={"U1": "alice", "U2": "bob"})
    chat_log = ChatLog()

    assert not handle_message_event(
        engine, client, {**event("what a day"), "user": "U2"}, cfg, chat_log=chat_log
    )
    handle_message_event(engine, client, event("tcl lindex [log] 0 3"), cfg, chat_log=chat_log)
    assert client.posted == [("C123", "```what a day```")]

    client.posted.clear()
    handle_message_event(engine, client, event("tcl llength [log]"), cfg, chat_log=chat_log)
    assert client.posted == [("C123", "```0```")]  # slurped by the previous eval


def test_channel_reaches_sandbox_as_irc_name(engine, cfg):
    # saved procs print [channel] and key cache buckets off it, so it has
    # to look like an irc channel, not a slack id
    client = StubClient()
    handle_message_event(engine, client, event("tcl channel"), cfg)
    assert client.posted == [("C123", "```#tcl```")]


def test_channel_falls_back_to_id(engine, cfg):
    client = StubClient(channel_names={})
    handle_message_event(engine, client, event("tcl channel"), cfg)
    assert client.posted == [("C123", "```C123```")]


@pytest.mark.parametrize(
    "raw,clean",
    [
        ("\x0304,04***\x03 hi", "*** hi"),
        ("\x02bold\x0f", "bold"),
        ("\x034red\x03", "red"),
        ("\x1funderline\x16", "underline"),
        ("no formatting", "no formatting"),
    ],
)
def test_strip_irc_formatting(raw, clean):
    assert strip_irc_formatting(raw) == clean


def test_reply_strips_irc_colors(engine, cfg):
    # ascii art from the state is full of mIRC colour codes; slack renders
    # none of them, leaving literal "04,04" garbage if not stripped
    client = StubClient()
    handle_message_event(engine, client, event("tcl set x {\x0304,04* art}"), cfg)
    assert client.posted == [("C123", "```* art```")]


def test_say_strips_irc_colors(engine, cfg):
    client = StubClient()
    handle_message_event(engine, client, event("tcl core::bot_say \x0304,04*\x03 said"), cfg)
    assert client.posted[0] == ("C123", "* said")


def test_nick_cache_caches(engine):
    client = StubClient(user_names={"U1": "alice"})
    cache = NickCache()
    assert cache.resolve(client, "U1") == "alice"
    client.user_names.clear()
    assert cache.resolve(client, "U1") == "alice"


def test_user_mentions_become_nicks(engine, cfg):
    # procs were written for irc: `deathto winkie` must see the nick, not
    # the raw <@U123> slack sends
    client = StubClient(user_names={"U1": "alice", "U99": "winkie"})
    handle_message_event(engine, client, event("tcl set x <@U99>"), cfg)
    assert client.posted == [("C123", "```winkie```")]


def test_mention_with_label_uses_the_label(engine, cfg):
    client = StubClient()
    handle_message_event(engine, client, event("tcl set x <@U99|winkie>"), cfg)
    assert client.posted == [("C123", "```winkie```")]


@pytest.mark.parametrize(
    "raw,resolved",
    [
        ("<#C5|general>", "#general"),
        ("<!here>", "here"),
        ("<!channel>", "channel"),
        ("<!subteam^S1|@team>", "@team"),
    ],
)
def test_other_mention_forms_resolved(engine, cfg, raw, resolved):
    client = StubClient()
    handle_message_event(engine, client, event(f"tcl set x {{{raw}}}"), cfg)
    assert client.posted == [("C123", f"```{resolved}```")]


@pytest.mark.parametrize(
    "hostile",
    ["<!channel>", "<!here>", "<!everyone>", "<@U404>", "<#C404|general>"],
)
def test_bot_cannot_be_used_as_a_ping_cannon(hostile):
    # a hostile eval (or a saved proc holding mention markup) must not be
    # able to notify a whole workspace on demand
    messages = format_reply(True, f"wake up {hostile}", [])
    assert len(messages) == 1
    assert hostile not in messages[0]


def test_replies_ask_slack_not_to_linkify(engine, cfg):
    calls = []

    class RecordingClient(StubClient):
        def chat_postMessage(self, **kwargs):
            calls.append(kwargs)
            return super().chat_postMessage(channel=kwargs["channel"], text=kwargs["text"])

    handle_message_event(engine, RecordingClient(), event("tcl expr {1 + 1}"), cfg)
    assert calls[0]["parse"] == "none"
    assert calls[0]["link_names"] is False
    assert calls[0]["unfurl_links"] is False


def test_event_deduper_claims_once():
    from smeggdrop.platforms.slack import EventDeduper

    d = EventDeduper()
    assert d.claim("Ev1") is True
    assert d.claim("Ev1") is False
    assert d.claim("Ev2") is True
    # no id to dedupe on: run it rather than lose it
    assert d.claim(None) is True
    assert d.claim(None) is True


def test_event_deduper_is_bounded():
    from smeggdrop.platforms.slack import EventDeduper

    d = EventDeduper(capacity=3)
    for i in range(10):
        assert d.claim(f"Ev{i}") is True
    assert len(d._seen) == 3
    assert d.claim("Ev9") is False  # recent ids still remembered
    assert d.claim("Ev0") is True  # oldest evicted


def test_capitalized_trigger_works_end_to_end(engine, cfg):
    client = StubClient()
    assert handle_message_event(engine, client, event("Tcl expr {6 * 7}"), cfg)
    assert client.posted == [("C123", "```42```")]


def test_env_trigger_is_also_case_insensitive():
    cfg = SlackConfig.from_env({"SMEGGDROP_TRIGGER": r"^!eval\s"})
    assert cfg.trigger.search("!EVAL puts hi")


class FlakyClient(StubClient):
    """Fails the first `failures` posts with a transient error."""

    def __init__(self, failures=1, error=None, **kw):
        super().__init__(**kw)
        self.failures = failures
        self.attempts = 0
        self.error = error or OSError("_ssl.c:983: The handshake operation timed out")

    def chat_postMessage(self, **kwargs):
        self.attempts += 1
        if self.attempts <= self.failures:
            raise self.error
        return super().chat_postMessage(channel=kwargs["channel"], text=kwargs["text"])


def test_transient_post_failure_is_retried(engine, cfg, monkeypatch):
    monkeypatch.setattr("smeggdrop.platforms.slack.POST_BACKOFF_SECONDS", 0)
    client = FlakyClient(failures=2)
    handle_message_event(engine, client, event("tcl expr {6 * 7}"), cfg)
    assert client.attempts == 3
    assert client.posted == [("C123", "```42```")]


def test_permanent_post_failure_is_not_retried(engine, cfg):
    client = FlakyClient(failures=5, error=RuntimeError("channel_not_found"))
    with pytest.raises(RuntimeError):
        handle_message_event(engine, client, event("tcl expr {6 * 7}"), cfg)
    assert client.attempts == 1


def test_retry_gives_up_and_raises(engine, cfg, monkeypatch):
    monkeypatch.setattr("smeggdrop.platforms.slack.POST_BACKOFF_SECONDS", 0)
    client = FlakyClient(failures=99)
    with pytest.raises(OSError):
        handle_message_event(engine, client, event("tcl expr {6 * 7}"), cfg)
    assert client.attempts == 3


@pytest.mark.parametrize(
    "error,transient",
    [
        (OSError("handshake operation timed out"), True),
        (OSError("Connection reset by peer"), True),
        (RuntimeError("ratelimited"), True),
        (RuntimeError("channel_not_found"), False),
        (RuntimeError("invalid_auth"), False),
    ],
)
def test_is_transient(error, transient):
    from smeggdrop.platforms.slack import is_transient

    assert is_transient(error) is transient


def test_retry_after_header_is_honoured():
    from smeggdrop.platforms.slack import retry_after_seconds

    class Response:
        status_code = 429
        headers = {"Retry-After": ["7"]}

    class Err(Exception):
        response = Response()

    assert retry_after_seconds(Err()) == 7.0


@pytest.mark.parametrize(
    "text,code",
    [
        ("tcl `snoe`", "snoe"),
        ("tcl ```expr {1 + 1}```", "expr {1 + 1}"),
        ("`tcl snoe`", "snoe"),
        ("tcl expr {1 + 1}", "expr {1 + 1}"),
    ],
)
def test_backtick_wrapped_commands_run(engine, cfg, text, code):
    # people copy commands out of code-formatted messages
    from smeggdrop.platforms.slack import unwrap_backticks, unfuck_slack_message
    from smeggdrop.platforms import extract_code

    extracted = extract_code(unfuck_slack_message(text), cfg.trigger)
    assert unwrap_backticks(extracted) == code


def test_backticked_command_evaluates(engine, cfg):
    client = StubClient()
    assert handle_message_event(engine, client, event("tcl `expr {6 * 7}`"), cfg)
    assert client.posted == [("C123", "```42```")]

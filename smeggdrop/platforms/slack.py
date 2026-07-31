"""Slack adapter: Events API on Lambda for prod, Socket Mode for dev.

Wiring lives in build_app()/run_socket_mode() (the only places slack_bolt
is imported); everything the adapter actually decides — trigger matching,
message unmangling, reply formatting, the event handler — is plain code
below, testable without the SDK.

Slack-facing security:
- request signatures are verified by bolt (signing secret); Socket Mode
  needs no public endpoint at all
- Events API retries are dropped by middleware: an eval can exceed Slack's
  3s ack window, and a retried event must not re-run user code
- everything in the message is untrusted input; it only ever reaches the
  engine (which sandboxes it) and chat_postMessage as data
"""

from __future__ import annotations

import html
import logging
import os
import re
import time
from collections import OrderedDict
from dataclasses import dataclass

from smeggdrop.engine import Engine, EvalRequest
from smeggdrop.platforms import DEFAULT_TRIGGER, ChatLog, chunk_output, extract_code

log = logging.getLogger(__name__)

# stay under slack's 4k-chars-per-message recommendation, few messages max
MAX_MESSAGE_CHARS = 3500
MAX_MESSAGES = 3


@dataclass
class SlackConfig:
    trigger: re.Pattern = DEFAULT_TRIGGER
    channels: frozenset[str] = frozenset()  # empty = all channels
    blocked_users: frozenset[str] = frozenset()  # slack user IDs, not names
    state_dir: str = "state"
    time_limit: int = 5
    words_file: str | None = None
    app_token: str | None = None  # xapp-, socket mode only
    # dynamo table for cross-container dedupe; empty = in-memory, which
    # is only correct when there is a single process (socket mode)
    dedupe_table: str | None = None

    @classmethod
    def from_env(cls, env=os.environ) -> "SlackConfig":
        channels = frozenset(
            c.strip() for c in env.get("SMEGGDROP_CHANNELS", "").split(",") if c.strip()
        )
        blocked_users = frozenset(
            u.strip() for u in env.get("SMEGGDROP_BLOCKED_USERS", "").split(",") if u.strip()
        )
        return cls(
            # case-insensitive like the default: chat clients capitalize
            trigger=re.compile(
                env.get("SMEGGDROP_TRIGGER", DEFAULT_TRIGGER.pattern), re.IGNORECASE
            ),
            channels=channels,
            blocked_users=blocked_users,
            state_dir=env.get("SMEGGDROP_STATE", "state"),
            time_limit=int(env.get("SMEGGDROP_TIME_LIMIT", "5")),
            words_file=env.get("SMEGGDROP_WORDS") or None,
            app_token=env.get("SLACK_APP_TOKEN") or None,
            dedupe_table=env.get("SMEGGDROP_DEDUPE_TABLE") or None,
        )


USER_MENTION = re.compile(r"<@([UW][A-Z0-9]+)(?:\|([^>]*))?>")
CHANNEL_MENTION = re.compile(r"<#[C][A-Z0-9]+(?:\|([^>]*))?>")
BROADCAST_MENTION = re.compile(r"<!(here|channel|everyone)(?:\|[^>]*)?>")
SPECIAL_MENTION = re.compile(r"<!([a-z_]+)(?:\^[^|>]*)?(?:\|([^>]*))?>")

# The bot has no slack identity of its own to be @-mentioned, so this is
# the only way "is claude around" is distinguishable from ordinary chat.
OPERATOR_MENTION = re.compile(r"\bclaude\b", re.IGNORECASE)


def unfuck_slack_message(text: str) -> str:
    """Undo slack's message mangling before trigger matching: unescape html
    entities, unwrap <url> / <url|label> links, and unwrap a fully-
    backticked message.

    Unescaping has to happen first: slack sometimes delivers link markup
    with the angle brackets as &lt;/&gt; entities (observed live — a user's
    <http://x|x> arrived that way), and the url-unwrap regex needs real `<`
    `>` characters to match. Getting this backwards doesn't leak anything
    (SafeFetcher.validate rejects a URL with stray `<>` for an unrelated
    reason — the scheme fails to parse), but it does mean a legitimately
    pasted link in that form would break with a confusing error.
    """
    text = html.unescape(text)
    text = unwrap_backticks(text)
    return re.sub(r"<(https?://[^|>]+)(?:\|[^>]*)?>", r"\1", text)


def unwrap_backticks(text: str) -> str:
    """Strip backticks that wrap the whole string.

    People copy commands out of code-formatted messages, so `tcl ``snoe``
    arrives with the code portion still fenced and fails as an invalid
    command name. Only unwrap when the fences enclose everything — a stray
    backtick inside real tcl is left alone.
    """
    match = re.fullmatch(r"\s*`{1,3}([^`].*?)`{1,3}\s*", text, re.S)
    return match.group(1) if match else text


def resolve_mentions(text: str, client, nicks: "NickCache") -> str:
    """Turn slack mention syntax into the plain nicks procs expect.

    The saved procs were written for irc, where `deathto winkie` gets the
    literal nick. Slack delivers `deathto <@U123>`, which procs then echo
    back verbatim — unreadable, and it re-pings the target.
    """
    text = USER_MENTION.sub(
        lambda m: m.group(2) or nicks.resolve(client, m.group(1)), text
    )
    text = CHANNEL_MENTION.sub(lambda m: f"#{m.group(1)}" if m.group(1) else "#channel", text)
    text = BROADCAST_MENTION.sub(lambda m: m.group(1), text)
    return SPECIAL_MENTION.sub(lambda m: m.group(2) or m.group(1), text)


def defang_mentions(text: str) -> str:
    """Neutralize anything in outgoing text that slack would turn into a
    notification.

    Otherwise the bot is a ping cannon: `tcl . <!channel> wake up` (or a
    saved proc that stores mention markup) would notify an entire
    workspace on demand, as many times as someone cares to ask. Code
    fences alone are not a guarantee, so strip the syntax itself and post
    with parse=none as well.
    """
    text = BROADCAST_MENTION.sub(lambda m: f"@​{m.group(1)}", text)
    text = USER_MENTION.sub(lambda m: f"@​{m.group(2) or m.group(1)}", text)
    text = CHANNEL_MENTION.sub(lambda m: f"#​{m.group(1) or 'channel'}", text)
    return SPECIAL_MENTION.sub(lambda m: f"@​{m.group(2) or m.group(1)}", text)


# mIRC formatting: bold/underline/reset/reverse, and colour (^C plus up to
# two digits, optionally ,digits). Slack renders none of it, and the digits
# show up as literal garbage in the middle of ascii art if left in.
IRC_FORMATTING = re.compile(r"[\x02\x1d\x1f\x0f\x16]|\x03\d{0,2}(?:,\d{1,2})?")


def strip_irc_formatting(text: str) -> str:
    return IRC_FORMATTING.sub("", text)


def format_reply(ok: bool, output: str, warnings: list[str]) -> list[str]:
    """Render an EvalResult as a list of slack messages (code blocks)."""
    output = defang_mentions(strip_irc_formatting(output))
    body = output if output else "(no output)"
    if not ok:
        body = f"error: {body}"
    body = body.replace("```", "'''")
    if warnings:
        body += "\n" + "\n".join(f"warning: {w}" for w in warnings)

    lines = chunk_output(body, max_chunk=MAX_MESSAGE_CHARS, max_chunks=MAX_MESSAGES * 50)
    messages: list[str] = []
    current = ""
    for line in lines:
        candidate = f"{current}\n{line}" if current else line
        if len(candidate) > MAX_MESSAGE_CHARS:
            messages.append(current)
            current = line
        else:
            current = candidate
    if current:
        messages.append(current)
    if len(messages) > MAX_MESSAGES:
        messages = messages[:MAX_MESSAGES]
        messages[-1] += "\n(truncated)"
    return [f"```{m}```" for m in messages]


class EventDeduper:
    """Remembers which slack event ids have been taken on.

    Retries do not mean "already done" — slack retries when it got no ack,
    which is exactly what happens while the bot is restarting. Dropping
    every retry loses those messages silently. Dropping by event id instead
    is the property actually wanted: run each event at most once, but do
    run one whose first delivery we never saw.
    """

    def __init__(self, capacity: int = 2048):
        self.capacity = capacity
        self._seen: OrderedDict[str, None] = OrderedDict()

    def claim(self, event_id: str | None) -> bool:
        """Record an event id. False if it was already claimed."""
        if not event_id:
            return True  # nothing to dedupe on; better to run than to drop
        if event_id in self._seen:
            self._seen.move_to_end(event_id)
            return False
        self._seen[event_id] = None
        while len(self._seen) > self.capacity:
            self._seen.popitem(last=False)
        return True


class DynamoDeduper:
    """Claims slack event ids in dynamo, so the claim is shared.

    EventDeduper keeps its record in memory, which means per process — and
    on lambda that means per container. Slack retries when it doesn't get an
    ack inside 3s, which a cold start is right on the edge of, and the retry
    is free to land on a *different* container that has never heard of the
    event. It runs the eval again and the channel gets two answers. Only a
    claim both containers can see fixes that.

    The claim is a conditional write: first writer wins, everyone else is a
    duplicate. Items carry a TTL because the claim only has to outlive
    slack's retry window, not be kept forever.
    """

    def __init__(self, table: str, ttl_seconds: int = 900, client=None):
        self.table = table
        self.ttl_seconds = ttl_seconds
        self._client = client

    @property
    def client(self):
        if self._client is None:
            import boto3  # imported lazily so the core stays dependency-free

            self._client = boto3.client("dynamodb")
        return self._client

    def claim(self, event_id: str | None) -> bool:
        if not event_id:
            return True  # nothing to dedupe on; better to run than to drop
        try:
            self.client.put_item(
                TableName=self.table,
                Item={
                    "event_id": {"S": event_id},
                    "expires_at": {"N": str(int(time.time()) + self.ttl_seconds)},
                },
                ConditionExpression="attribute_not_exists(event_id)",
            )
            return True
        except Exception as e:
            if type(e).__name__ == "ConditionalCheckFailedException":
                return False
            # A dynamo outage must not take the bot down with it. Answering
            # twice is a worse failure than not answering at all, so fall
            # back to running the event rather than dropping it.
            log.warning("dedupe claim failed for %s, running anyway: %s", event_id, e)
            return True


def make_deduper(cfg: "SlackConfig"):
    return DynamoDeduper(cfg.dedupe_table) if cfg.dedupe_table else EventDeduper()


def event_id_of(body) -> str | None:
    if isinstance(body, dict):
        return body.get("event_id")
    return None


def retry_attempt(headers) -> int:
    """Slack's retry counter: 0 (or absent) on first delivery, >=1 on retry.

    Bolt stores header values as lists, and Socket Mode synthesizes the
    header from the envelope's retry_attempt, so it is present even when
    nothing has been retried.
    """
    raw = (headers or {}).get("x-slack-retry-num")
    if isinstance(raw, (list, tuple)):
        raw = raw[0] if raw else None
    if raw is None or raw == "":
        return 0
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


def is_lazy_invocation(headers) -> bool:
    """True when bolt is re-invoking us to run a lazy listener.

    On lambda an event is handled by two invocations of the same function:
    the first acks inside slack's 3s window, then bolt invokes the function
    again to do the real work. Both carry the same slack event id, but the
    second is bolt calling us rather than slack redelivering, so it must not
    be deduped. It also frequently lands on the same warm container that
    just claimed that id -- dedupe it and the eval never runs at all, which
    looks like a bot that acks everything and answers nothing.

    Bolt's lazy runner always sets the function name alongside the flag, so
    require both: exempting a request from deduping is worth being narrow
    about, and one stray header shouldn't be enough to do it.
    """

    def value(name):
        raw = (headers or {}).get(name)
        if isinstance(raw, (list, tuple)):
            raw = raw[0] if raw else None
        return raw

    return bool(value("x-slack-bolt-lazy-only")) and bool(
        value("x-slack-bolt-lazy-function-name")
    )


class NickCache:
    """user id -> display name via users.info, cached; falls back to the id."""

    def __init__(self):
        self._names: dict[str, str] = {}

    def resolve(self, client, user_id: str) -> str:
        if not user_id:
            return "unknown"
        if user_id not in self._names:
            try:
                info = client.users_info(user=user_id)
                user = info["user"]
                self._names[user_id] = (
                    user.get("profile", {}).get("display_name")
                    or user.get("name")
                    or user_id
                )
            except Exception:
                self._names[user_id] = user_id
        return self._names[user_id]


class ChannelCache:
    """channel id -> #name via conversations.info, cached.

    Saved procs treat [channel] as an irc channel name (they print it, and
    they key cache buckets off it), so the sandbox sees "#tcl" while the
    api calls keep using the id. Falls back to the id.
    """

    def __init__(self):
        self._names: dict[str, str] = {}

    def resolve(self, client, channel_id: str) -> str:
        if not channel_id:
            return ""
        if channel_id not in self._names:
            try:
                info = client.conversations_info(channel=channel_id)
                name = info["channel"].get("name")
                self._names[channel_id] = f"#{name}" if name else channel_id
            except Exception:
                self._names[channel_id] = channel_id
        return self._names[channel_id]


def handle_message_event(
    engine: Engine,
    client,
    event: dict,
    cfg: SlackConfig,
    nicks: NickCache | None = None,
    chat_log: ChatLog | None = None,
    channels: ChannelCache | None = None,
) -> bool:
    """Process one message event. Returns True if an eval ran."""
    subtype = event.get("subtype")
    if subtype == "message_changed":
        msg = event.get("message") or {}
    elif subtype is None:
        msg = event
    else:
        return False  # joins, topic changes, bot_message, etc.
    if msg.get("bot_id") or msg.get("subtype"):
        return False  # never evaluate our own (or any bot's) output

    channel = event.get("channel") or ""
    if cfg.channels and channel not in cfg.channels:
        return False

    # keyed on the immutable slack user id, never on nick/display name
    # (which is user-controlled and can be changed or duplicated)
    if (msg.get("user") or "") in cfg.blocked_users:
        return False

    text = msg.get("text") or ""
    user_id = msg.get("user") or ""
    resolver = nicks or NickCache()
    nick = resolver.resolve(client, user_id) if user_id else msg.get("username", "unknown")

    cleaned = resolve_mentions(unfuck_slack_message(text), client, resolver)
    code = extract_code(cleaned, cfg.trigger)
    if code is not None:
        # the trigger may have been outside the fences: "tcl `snoe`"
        code = unwrap_backticks(code)
    if code is None or not code.strip():
        if chat_log is not None and cleaned:
            chat_log.append(channel, nick, user_id or None, cleaned)
        if cleaned and OPERATOR_MENTION.search(cleaned):
            # plain chat never otherwise produces a log line, so someone
            # addressing the operator by name is invisible unless it's
            # logged on purpose. This doesn't page or reply -- a human is
            # expected to be watching the logs.
            channel_name = (channels or ChannelCache()).resolve(client, channel)
            log.info("mention: %s in %s: %r", nick, channel_name, cleaned[:200])
        return False

    channel_name = (channels or ChannelCache()).resolve(client, channel)
    log.info("eval from %s in %s: %r", nick, channel_name, code[:120])
    result = engine.eval(
        EvalRequest(
            code=code,
            nick=nick,
            channel=channel_name,
            mask=user_id or None,
            loglines=chat_log.slurp(channel) if chat_log is not None else (),
        ),
        say=lambda t: post(client, channel, defang_mentions(strip_irc_formatting(t))),
    )
    # log the outcome, not just the input: an operator (or whoever is
    # babysitting a fresh deploy) needs to see which evals are failing and
    # what the sandbox refused, without reading the channel
    if result.ok:
        log.info("eval ok for %s: %s", nick, summarize(result.output))
    else:
        log.warning("eval error for %s: %s -> %s", nick, code[:80], summarize(result.output))
    for warning in result.warnings:
        log.warning("eval warning for %s: %s", nick, warning)

    for message in format_reply(result.ok, result.output, result.warnings):
        post(client, channel, message)
    return True


POST_ATTEMPTS = 3
POST_BACKOFF_SECONDS = 0.5


def post(client, channel: str, text: str):
    """Post eval output. Everything here is attacker-influenced, so slack is
    told not to linkify, unfurl, or resolve names in it.

    Retries transient failures: a TLS handshake timeout or a rate limit
    here means the eval ran but its answer never arrived, which reads in
    channel as the bot ignoring you.
    """
    delay = POST_BACKOFF_SECONDS
    for attempt in range(1, POST_ATTEMPTS + 1):
        try:
            return client.chat_postMessage(
                channel=channel,
                text=text,
                parse="none",
                link_names=False,
                unfurl_links=False,
                unfurl_media=False,
            )
        except Exception as e:  # noqa: BLE001 — sdk raises several types
            if attempt == POST_ATTEMPTS or not is_transient(e):
                raise
            wait = retry_after_seconds(e) or delay
            log.warning("post failed (%s), retrying in %.1fs", e, wait)
            time.sleep(wait)
            delay *= 2


TRANSIENT_MARKERS = (
    "timed out",
    "timeout",
    "connection",
    "handshake",
    "temporarily unavailable",
    "ratelimited",
    "rate limited",
    "server_error",
    "service_unavailable",
    "internal_error",
)


def is_transient(error: Exception) -> bool:
    status = getattr(getattr(error, "response", None), "status_code", None)
    if status is not None and (status == 429 or status >= 500):
        return True
    return any(m in str(error).lower() for m in TRANSIENT_MARKERS)


def retry_after_seconds(error: Exception) -> float | None:
    headers = getattr(getattr(error, "response", None), "headers", None) or {}
    raw = headers.get("Retry-After") or headers.get("retry-after")
    if isinstance(raw, (list, tuple)):
        raw = raw[0] if raw else None
    try:
        return float(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None


def summarize(text: str, limit: int = 160) -> str:
    """One-line, length-capped rendering of eval output for logs."""
    flat = " ".join(strip_irc_formatting(text or "").split())
    return flat[:limit] + ("..." if len(flat) > limit else "")


def build_app(engine: Engine, cfg: SlackConfig, *, lazy: bool = False, **app_kwargs):
    """Build the bolt app.

    lazy=True is the FaaS wiring: ack inside slack's 3s window, then do the
    eval in a lazy listener, which on Lambda means a second invocation of
    the function. Off FaaS that machinery buys nothing (bolt just runs the
    lazy listener in its thread pool), so the socket-mode path registers an
    ordinary listener and lets bolt ack before running it.
    """
    from slack_bolt import App

    app = App(process_before_response=lazy, **app_kwargs)
    nicks = NickCache()
    channels = ChannelCache()
    chat_log = ChatLog()
    deduper = make_deduper(cfg)

    @app.middleware
    def drop_duplicates(request, next):
        # Run each event at most once. Note the retry header is present on
        # first delivery too, valued 0, so testing for its presence drops
        # everything; and a retry whose original we never handled (bot was
        # restarting) still deserves to run, so key off the event id rather
        # than the retry counter.
        # The lazy re-invocation repeats the event id the ack already
        # claimed; it is our own second half, not a redelivery.
        if is_lazy_invocation(request.headers):
            next()
            return
        event_id = event_id_of(request.body)
        if not deduper.claim(event_id):
            log.info(
                "dropping duplicate delivery of %s (retry %d)",
                event_id,
                retry_attempt(request.headers),
            )
            return
        next()

    def evaluate(event, client, logger):
        try:
            handle_message_event(engine, client, event, cfg, nicks, chat_log, channels)
        except Exception:
            logger.exception("eval handler failed")

    if lazy:
        app.event("message")(ack=lambda ack: ack(), lazy=[evaluate])
    else:
        app.event("message")(evaluate)
    return app


def run_socket_mode(engine: Engine, cfg: SlackConfig) -> None:
    from slack_bolt.adapter.socket_mode import SocketModeHandler

    if not cfg.app_token:
        raise SystemExit("SLACK_APP_TOKEN (xapp-...) is required for socket mode")
    app = build_app(engine, cfg)
    log.info("starting socket mode")
    SocketModeHandler(app, cfg.app_token).start()

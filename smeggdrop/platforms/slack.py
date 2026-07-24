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
    state_dir: str = "state"
    time_limit: int = 5
    words_file: str | None = None
    app_token: str | None = None  # xapp-, socket mode only

    @classmethod
    def from_env(cls, env=os.environ) -> "SlackConfig":
        channels = frozenset(
            c.strip() for c in env.get("SMEGGDROP_CHANNELS", "").split(",") if c.strip()
        )
        return cls(
            trigger=re.compile(env.get("SMEGGDROP_TRIGGER", DEFAULT_TRIGGER.pattern)),
            channels=channels,
            state_dir=env.get("SMEGGDROP_STATE", "state"),
            time_limit=int(env.get("SMEGGDROP_TIME_LIMIT", "5")),
            words_file=env.get("SMEGGDROP_WORDS") or None,
            app_token=env.get("SLACK_APP_TOKEN") or None,
        )


def unfuck_slack_message(text: str) -> str:
    """Undo slack's message mangling before trigger matching: unwrap
    <url> / <url|label> links, unwrap a fully-backticked message, and
    unescape html entities."""
    text = re.sub(r"<(https?://[^|>]+)(?:\|[^>]*)?>", r"\1", text)
    m = re.fullmatch(r"\s*`{1,3}(.+?)`{1,3}\s*", text, re.S)
    if m:
        text = m.group(1)
    return html.unescape(text)


# mIRC formatting: bold/underline/reset/reverse, and colour (^C plus up to
# two digits, optionally ,digits). Slack renders none of it, and the digits
# show up as literal garbage in the middle of ascii art if left in.
IRC_FORMATTING = re.compile(r"[\x02\x1d\x1f\x0f\x16]|\x03\d{0,2}(?:,\d{1,2})?")


def strip_irc_formatting(text: str) -> str:
    return IRC_FORMATTING.sub("", text)


def format_reply(ok: bool, output: str, warnings: list[str]) -> list[str]:
    """Render an EvalResult as a list of slack messages (code blocks)."""
    output = strip_irc_formatting(output)
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

    text = msg.get("text") or ""
    user_id = msg.get("user") or ""
    nick = (nicks or NickCache()).resolve(client, user_id) if user_id else msg.get("username", "unknown")

    code = extract_code(unfuck_slack_message(text), cfg.trigger)
    if code is None or not code.strip():
        if chat_log is not None and text:
            chat_log.append(channel, nick, user_id or None, text)
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
        say=lambda t: client.chat_postMessage(
            channel=channel, text=strip_irc_formatting(t)
        ),
    )
    for message in format_reply(result.ok, result.output, result.warnings):
        client.chat_postMessage(channel=channel, text=message)
    return True


def build_app(engine: Engine, cfg: SlackConfig, **app_kwargs):
    """Bolt app wired for FaaS: ack within 3s, eval in a lazy listener."""
    from slack_bolt import App

    app = App(process_before_response=True, **app_kwargs)
    nicks = NickCache()
    channels = ChannelCache()
    chat_log = ChatLog()

    @app.middleware
    def drop_retries(request, next):
        # a retried delivery means our ack was slow, not that the eval
        # didn't happen; re-running user code is worse than dropping
        if request.headers.get("x-slack-retry-num"):
            return
        next()

    def ack_only(ack):
        ack()

    def evaluate(event, client, logger):
        try:
            handle_message_event(engine, client, event, cfg, nicks, chat_log, channels)
        except Exception:
            logger.exception("eval handler failed")

    app.event("message")(ack=ack_only, lazy=[evaluate])
    return app


def run_socket_mode(engine: Engine, cfg: SlackConfig) -> None:
    from slack_bolt.adapter.socket_mode import SocketModeHandler

    if not cfg.app_token:
        raise SystemExit("SLACK_APP_TOKEN (xapp-...) is required for socket mode")
    app = build_app(engine, cfg)
    log.info("starting socket mode")
    SocketModeHandler(app, cfg.app_token).start()

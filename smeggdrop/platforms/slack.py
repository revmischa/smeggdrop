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
from dataclasses import dataclass, field

from smeggdrop.engine import Engine, EvalRequest
from smeggdrop.platforms import DEFAULT_TRIGGER, chunk_output, extract_code

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


def format_reply(ok: bool, output: str, warnings: list[str]) -> list[str]:
    """Render an EvalResult as a list of slack messages (code blocks)."""
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


def handle_message_event(
    engine: Engine, client, event: dict, cfg: SlackConfig, nicks: NickCache | None = None
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
    code = extract_code(unfuck_slack_message(text), cfg.trigger)
    if code is None or not code.strip():
        return False

    user_id = msg.get("user") or ""
    nick = (nicks or NickCache()).resolve(client, user_id) if user_id else msg.get("username", "unknown")
    log.info("eval from %s in %s: %r", nick, channel, code[:120])

    result = engine.eval(
        EvalRequest(code=code, nick=nick, channel=channel, mask=user_id or None),
        say=lambda t: client.chat_postMessage(channel=channel, text=t),
    )
    for message in format_reply(result.ok, result.output, result.warnings):
        client.chat_postMessage(channel=channel, text=message)
    return True


def build_app(engine: Engine, cfg: SlackConfig, **app_kwargs):
    """Bolt app wired for FaaS: ack within 3s, eval in a lazy listener."""
    from slack_bolt import App

    app = App(process_before_response=True, **app_kwargs)
    nicks = NickCache()

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
            handle_message_event(engine, client, event, cfg, nicks)
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

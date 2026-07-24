"""AWS Lambda entrypoint for the slack adapter (Events API).

The engine and bolt app are built once per execution environment and reused
across invocations, so the interp stays warm. Evals are serialized by the
engine's worker thread; run this function with reserved concurrency 1 until
the S3 state store lands — with the file store, state only persists for the
life of a warm container (mount EFS at SMEGGDROP_STATE if you need
durability before then).

Lazy listeners re-invoke this same function (bolt's FaaS pattern), so the
function role needs lambda:InvokeFunction on itself.
"""

from __future__ import annotations

import logging
from functools import lru_cache

logging.basicConfig(level=logging.INFO)


@lru_cache(maxsize=1)
def _handler():
    from slack_bolt.adapter.aws_lambda import SlackRequestHandler

    from smeggdrop.engine import Engine, Limits
    from smeggdrop.platforms.slack import SlackConfig, build_app
    from smeggdrop.state import FileStateStore

    cfg = SlackConfig.from_env()
    engine = Engine(
        FileStateStore(cfg.state_dir),
        limits=Limits(eval_time_seconds=cfg.time_limit),
        words_file=cfg.words_file,
    )
    return SlackRequestHandler(build_app(engine, cfg))


def handler(event, context):
    return _handler().handle(event, context)

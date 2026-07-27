"""AWS Lambda entrypoint for the slack adapter (Events API).

The engine and bolt app are built once per execution environment and reused
across invocations, so the interp stays warm. Evals are serialized by the
engine's worker thread; run this function with reserved concurrency 1.

Point SMEGGDROP_STATE at s3://bucket/prefix for durable state — the file
store only lasts as long as a warm container. The S3 store merges
concurrent writers rather than clobbering them, but single-writer is still
the intended configuration.

Lazy listeners re-invoke this same function (bolt's FaaS pattern), so the
function role needs lambda:InvokeFunction on itself.
"""

from __future__ import annotations

import logging
from functools import lru_cache

# The lambda runtime installs a root handler before this module is imported,
# so basicConfig() returns without doing anything and every eval log line is
# filtered out at the default WARNING level. Set the level on the root logger
# directly so the operator can still see what is being evaluated and by whom.
logging.getLogger().setLevel(logging.INFO)


@lru_cache(maxsize=1)
def _handler():
    from slack_bolt.adapter.aws_lambda import SlackRequestHandler

    from smeggdrop.engine import Engine, Limits
    from smeggdrop.platforms.slack import SlackConfig, build_app
    from smeggdrop.state import open_store

    cfg = SlackConfig.from_env()
    engine = Engine(
        open_store(cfg.state_dir),
        limits=Limits(eval_time_seconds=cfg.time_limit),
        words_file=cfg.words_file,
    )
    return SlackRequestHandler(build_app(engine, cfg, lazy=True))


def handler(event, context):
    return _handler().handle(event, context)

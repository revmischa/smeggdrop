"""Process-level containment for the bot.

The Tcl sandbox stops chat code from touching the filesystem, the network
(except through the guarded fetcher) and the process environment. What it
cannot stop is a single well-formed command asking for absurd resources:
`string repeat x 9999999999` is one command, so neither the time limit nor
the command limit sees it coming — Tcl just tries the allocation.

An address-space rlimit turns that from "the host starts swapping and the
OOM killer picks a victim" into "this process dies and the supervisor
restarts it". Tcl's allocator aborts on failure, so the bot does not
survive the hit; that is the intended trade. Restarting is cheap (state is
on disk), and a hostile eval taking down someone else's process on the
same box is not.

Applied at startup by the CLI; on Lambda the platform already caps memory
so this is a no-op unless SMEGGDROP_MEMORY_MB is set.
"""

from __future__ import annotations

import logging
import os

log = logging.getLogger(__name__)

DEFAULT_MEMORY_MB = 2048


def apply_memory_limit(megabytes: int | None = None) -> int | None:
    """Cap the process address space. Returns the applied cap, or None.

    Reads SMEGGDROP_MEMORY_MB when no value is passed; set it to 0 to
    disable. Never raises — a missing rlimit is a weaker deployment, not a
    reason to refuse to start.
    """
    if megabytes is None:
        raw = os.environ.get("SMEGGDROP_MEMORY_MB")
        megabytes = DEFAULT_MEMORY_MB if raw is None else int(raw)
    if not megabytes:
        return None

    try:
        import resource
    except ImportError:  # not posix
        log.warning("no resource module; memory limit not applied")
        return None

    limit = megabytes * 1024 * 1024
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    if hard != resource.RLIM_INFINITY and limit > hard:
        limit = hard
    try:
        resource.setrlimit(resource.RLIMIT_AS, (limit, hard))
    except (ValueError, OSError) as e:
        log.warning("could not set memory limit: %s", e)
        return None
    log.info("address space capped at %d MB", limit // (1024 * 1024))
    return limit // (1024 * 1024)

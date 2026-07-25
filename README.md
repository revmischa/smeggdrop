# smeggdrop

Evaluates Tcl in chat rooms. Say `tcl expr {6 * 7}` in a channel and the bot
answers `42`. Procs and variables defined in chat persist — the interpreter's
state is snapshotted, diffed and written to disk after every eval, so a
channel accumulates a shared library of procs over the years.

A fork of Sam Stephenson's smeggdrop, by way of the perl "shittybot" era
(still in [`app/`](app/) until the port is done). The current implementation
is Python; the interpreter is real Tcl via the stdlib's `tkinter` binding —
no Tk, no display, no native extensions. Plan and progress: [#2](https://github.com/revmischa/smeggdrop/issues/2).

## Running

Needs Python ≥ 3.11 with tkinter (Debian/Ubuntu: `apt install python3-tk`).

```sh
uv sync

# hack on the interpreter locally, no chat platform needed
uv run smeggdrop --state state-local repl

# check every saved proc in a state dir: loads? runs? references dead commands?
uv run smeggdrop --state state-local audit
uv run smeggdrop --state state-local audit --json > report.json

uv run pytest
```

The state directory format is unchanged from the perl bot (sha1-named
proc/var files plus an `_index` per category), so an existing state dir
works as-is.

`audit` exists so the port can be verified against real accumulated state:
it loads everything into a throwaway sandbox (nothing persisted, network
stubbed out), flags procs that fail to load or reference commands that no
longer exist, and actually calls every proc that's callable without
arguments. Fix, re-run, repeat.

## Security model

All chat input is untrusted and gets evaluated anyway — that's the product —
so containment is layered:

- code runs in a Tcl `interp create -safe` slave: no `exec`, `open`, `file`,
  `socket`, `source`, env access, or filesystem
- every eval has a wall-clock limit enforced by the master interp; slaves
  cannot modify their own limits
- host values (nick, channel, code) cross into Tcl as quoted list words,
  never by string interpolation
- `core::curl` (the sandbox's only network access) allows plain http(s) to
  public addresses only — no loopback/RFC1918/link-local/metadata/CGNAT
  targets, redirects re-validated per hop, responses size-capped — and is
  call-limited per eval
- `core::bot_say` is call-limited per eval; eval output is truncated before
  it reaches a platform
- persistence is vetted: per-eval caps on change count and value size, and
  names that would corrupt the index format are refused (state files are
  named by sha1, so names never become paths)

Residual risks worth knowing: DNS rebinding can slip past the fetcher's
resolve-time checks (run the bot with no reachable internal network — a
Lambda outside any VPC — and it's moot), and Tcl has no per-interp memory
cap (a hostile eval can balloon the process; process-level limits are the
backstop).

## Architecture

```
smeggdrop/
  interp.py     safe slave interp: bootstrap, context, per-eval limits
  engine.py     versioned eval: snapshot -> eval -> diff -> persist
  state.py      file store, byte-compatible with the perl layout
  security.py   SSRF-guarded fetcher behind core::curl
  audit.py      state verification (the `audit` subcommand)
  platforms/    adapters; the engine never imports platform SDKs
  tcl/          bootstrap sourced into the slave (from the perl tree)
```

Platform adapters do three things: decide whether a message triggers an
eval, build an `EvalRequest`, deliver the reply. Slack (Events API +
Lambda, Socket Mode for dev) is next; Discord is a planned adapter via the
interactions endpoint.

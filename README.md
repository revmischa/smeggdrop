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

## Slack

Create a Slack app with bot scopes `chat:write`, `users:read`,
`channels:history` (plus `groups:history` for private channels) and
subscribe to the `message.channels` (and `message.groups`) events. Then
say `tcl expr {6 * 7}` in a channel the bot is in.

[`slack-app-manifest.yml`](slack-app-manifest.yml) has all of that ready
to paste into *Create New App → From an app manifest*.

Local development uses Socket Mode (no public endpoint; enable it in the
app config and mint an `xapp-` token with `connections:write`). Put the
credentials in `.env` (gitignored) and use the dev script:

```sh
cat > .env <<'EOF'
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
EOF

./run-slack-dev.sh state-local          # or any state dir
```

Slack-specific behaviour worth knowing: mentions are resolved to plain
nicks on the way in, so procs written for irc see `deathto winkie` rather
than `deathto <@U03S5JZ7U>`; mIRC colour codes are stripped from replies
(Slack renders none of them, and the digits would litter the ascii art);
and `[channel]` reports `#name`, not the channel id, because saved procs
print it and key cache buckets off it.

Production runs the Events API on Lambda from a container image
([`Dockerfile.lambda`](Dockerfile.lambda)):

- point the app's event request URL at the function URL / API Gateway;
  set `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` on the function
- set **reserved concurrency to 1** — evals are serialized by design
- grant the function role `lambda:InvokeFunction` on itself (bolt's lazy
  listeners ack within Slack's 3s window, then re-invoke to run the eval)
- state is ephemeral per warm container until the S3 store lands; mount
  EFS at `SMEGGDROP_STATE` if you need durability before then

Config env vars: `SMEGGDROP_TRIGGER` (default `^\s*tcl\s`),
`SMEGGDROP_CHANNELS` (comma-separated channel IDs, empty = all),
`SMEGGDROP_STATE`, `SMEGGDROP_TIME_LIMIT`, `SMEGGDROP_WORDS`,
`SMEGGDROP_MEMORY_MB` (default 2048, 0 disables).

Request signatures are verified by bolt. Retried deliveries are dropped
rather than re-evaluated — running someone's code twice is worse than
missing it — which does mean a message sent while the bot is restarting is
lost rather than executed late.

`audit` exists so the port can be verified against real accumulated state:
it loads everything into a throwaway sandbox (nothing persisted, network
stubbed out), flags procs that fail to load or reference commands that no
longer exist, and calls them. `--call-with-args` passes a dummy value per
required argument so the whole library gets exercised rather than just the
zero-argument part, and sorts "wanted a number, got `test`" into its own
bucket instead of counting it as breakage. Fix, re-run, repeat.

Against the hardchats state (6,603 procs accumulated 2007-2017):

| | procs |
|---|---|
| ran clean | 5,256 |
| reached the network (stubbed in audit) | 729 |
| failed | 346 |
| wanted different arguments than the audit passes | 233 |
| timed out | 38 |
| failed to load | 0 |

So ~91% demonstrably work. Nearly all remaining failures are data rot
rather than port breakage: helpers their authors deleted years ago,
services that no longer resolve (`i.buttes.org`, `magick.buttes.org`), and
a few deliberate infinite loops.

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
- the process address space is capped (`SMEGGDROP_MEMORY_MB`, default 2 GB).
  Tcl has no per-interp memory limit and a single command —
  `string repeat x 40000000000` — outruns both the clock and any command
  counter, so this is what stops one eval from taking the host down with
  it. The bot dies and restarts instead; state is on disk, restarts are
  cheap.
- outgoing text has Slack mention syntax defanged and posts with
  `parse=none`, so the bot can't be driven as an `@channel` ping cannon

`tests/test_sandbox_escape.py` is the adversarial suite: token theft via
`::env`, filesystem reads, LAN and cloud-metadata SSRF, nested-interp
escapes, limit lifting, `exit`, path traversal, flooding.

Two notes on limits, both learned the hard way. Tcl's `interp limit
... command` counter is **cumulative for the interpreter's lifetime**, not
per-eval, so a fixed ceiling is permanently tripped by the first runaway
loop and every later eval fails — one `while 1 {}` becomes a channel-wide
denial of service. The wall-clock limit is checked at the same granularity
and resets per eval, so that is the one to rely on.

Residual risk worth knowing: DNS rebinding can slip past the fetcher's
resolve-time checks. Run the bot somewhere with no reachable internal
network (a Lambda outside any VPC) and it's moot.

## Architecture

```
smeggdrop/
  interp.py     safe slave interp: bootstrap, context, per-eval limits
  engine.py     versioned eval: snapshot -> eval -> diff -> persist
  state.py      file store, byte-compatible with the perl layout
  security.py   SSRF-guarded fetcher behind core::curl
  hardening.py  process-level containment (address space cap)
  audit.py      state verification (the `audit` subcommand)
  platforms/    adapters; the engine never imports platform SDKs
  tcl/          bootstrap sourced into the slave (from the perl tree)
```

Platform adapters do three things: decide whether a message triggers an
eval, build an `EvalRequest`, deliver the reply. Slack (Events API +
Lambda, Socket Mode for dev) is next; Discord is a planned adapter via the
interactions endpoint.

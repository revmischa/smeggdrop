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

Edited state some other way while the bot's up (a one-off `smeggdrop repl`
fix)? `./reload-bot.sh state-local` reloads it from disk without dropping
the Slack connection or restarting the process — the reload is queued on
the same worker thread evals run on, so it can't interrupt one in flight,
and Socket Mode never reconnects. It's a signal (`SIGHUP`), not a lock:
the file store still has no cross-process write coordination, so this
doesn't protect against a repl edit and a live eval writing at the exact
same instant — it just avoids the multi-second outage a full restart costs.

Slack-specific behaviour worth knowing: mentions are resolved to plain
nicks on the way in, so procs written for irc see `deathto winkie` rather
than `deathto <@U03S5JZ7U>`; mIRC colour codes are stripped from replies
(Slack renders none of them, and the digits would litter the ascii art);
and `[channel]` reports `#name`, not the channel id, because saved procs
print it and key cache buckets off it.

Production runs the Events API on Lambda instead, from a container image —
see [Deploying to AWS](#deploying-to-aws), which wires all of that up.
Socket Mode and a request URL are mutually exclusive, so an app does one or
the other, not both.

## State stores

`--state` (and `SMEGGDROP_STATE`) takes a directory or an `s3://` uri, and
`migrate` copies between them:

```sh
uv run smeggdrop --state ./state-local migrate s3://my-bucket/smeggdrop
```

The directory layout is the perl bot's (one sha1-named file per proc plus
an `_index`). S3 packs each category into a single JSON object instead:
6,600 objects would mean 6,600 GETs on every cold start, while the whole
state is ~6 MB — one GET to load, one PUT per eval that changes something.
Turn on bucket versioning and every eval becomes a restorable version.

Writes are conditional on the ETag that was loaded, so if a second process
does write, its changes are merged rather than clobbered. That's a backstop
for cold-start overlap, not a licence to run more than one writer.

Packing per category cuts cold-start GETs, but it also means every eval
that changes anything rewrites a whole ~6 MB blob, so versions pile up per
*eval*, not per changed proc. The deployed bucket keeps the 200 most recent
noncurrent versions and expires them after 90 days — enough to walk back a
bad eval without unbounded growth. Versioning only survives a bad write
though, not the bucket going away, so AWS Backup takes a daily copy into a
separate vault with 35-day retention.

Config env vars: `SMEGGDROP_TRIGGER` (default `^\s*tcl\s`),
`SMEGGDROP_CHANNELS` (comma-separated channel IDs, empty = all),
`SMEGGDROP_BLOCKED_USERS` (comma-separated slack user IDs — not
names, which anyone can change — silently ignored, no reply),
`SMEGGDROP_STATE`, `SMEGGDROP_TIME_LIMIT`, `SMEGGDROP_WORDS`,
`SMEGGDROP_MEMORY_MB` (default 2048, 0 disables),
`SMEGGDROP_DEDUPE_TABLE` (dynamo table for cross-container dedupe).

Request signatures are verified by bolt. Each slack event id runs at most
once, but a retry whose first delivery was never acked — the bot was
restarting — still runs, instead of being dropped for merely looking like a
retry. On lambda one event arrives as two invocations carrying the same
event id (ack, then eval), so bolt's own re-invocation is exempt from that
check; deduping it would drop every eval.

Where that claim is kept matters. In one process an in-memory record is
enough, but on lambda "one process" means "one container": Slack retries an
event it hasn't seen acked within 3s — which a cold start is right on the
edge of — and the retry is free to land on a container that has never heard
of it. Both run the eval and the channel gets answered twice, which is how
it showed up in practice. Set `SMEGGDROP_DEDUPE_TABLE` to a dynamo table and
the claim becomes a conditional write every container can see; leave it
unset for socket mode, where in-memory is correct. If dynamo is unreachable
the event runs rather than being dropped — a duplicate answer beats silence.

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

The failure count is also pessimistic in a way that can't be automated
away: plenty of procs raise on purpose, because the error message is the
joke — `ncock 24` answers "COCK SIZE OFF THE CHARTS", and a handful more
refuse with `please see a dentist for further assistance`. Those are
working procs that the audit has no way to tell apart from broken ones.

## Deploying to AWS

`sst.config.ts` (SST v4) deploys the slack adapter as a container-image
lambda behind a function URL, with state in a versioned S3 bucket.

```sh
./deploy.sh secret set SlackBotToken xoxb-...
./deploy.sh secret set SlackSigningSecret ...
./deploy.sh secret set SlackChannels C03QKEXDS
./deploy.sh deploy
```

`deploy.sh` wraps `sst`: the target account is reached by assuming a role
from an SSO profile, and sst's go sdk resolves `source_profile` to the
static keys in `~/.aws/credentials` rather than the sso session, so the
wrapper resolves the chain with the aws cli and hands sst the temporary
credentials that fall out. Needs a running docker daemon.

Seed the proc library before first use:

```sh
uv run --with boto3 smeggdrop --state ./state migrate s3://<bucket>/state
```

### Why a container

The engine runs tcl through `tkinter`, and the AWS lambda python base image
has no `_tkinter` — the debian python image links against the system libtcl
and does, so `Dockerfile` builds on that and installs the runtime interface
client explicitly. sst sets `imageConfig.commands` to the handler, which
arrives as CMD, so ENTRYPOINT is the RIC.

That rules out SnapStart, which supports neither container images nor —
more to the point — a state store that must not be frozen: it snapshots at
publish time, so restored environments would boot with a stale proc
library. It would also buy almost nothing here. Of a measured 2.75s cold
start, imports are ~30ms; the rest is fetching state from S3 and
installing 6,600 procs into a fresh interp, which a snapshot can't skip.
Warm invocations are ~0.1s. Raising memory from 2048 to 3008 MB changed
nothing (the work is I/O-bound, and peak usage is 134 MB).

### Switching slack over

Socket mode and an Events API request URL are mutually exclusive. To cut
over from a locally-run bot: disable socket mode in the app config, set the
function URL as the request URL under Event Subscriptions, then stop the
local process. Until that switch, the deployed function receives nothing.

Two caveats worth knowing. Each warm container holds its own interp, built
from state at its cold start, and doesn't see writes made by another
container until it recycles — the S3 store merges concurrent writers rather
than clobbering them, but containers can still diverge for a while under
real concurrency. And a fresh AWS account starts at 10 concurrent
executions and a 3008 MB memory ceiling until support raises them.

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

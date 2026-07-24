"""Command-line entry points: a local repl and the state audit."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from smeggdrop.audit import audit_state
from smeggdrop.engine import Engine, EvalRequest, Limits
from smeggdrop.state import FileStateStore


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="smeggdrop")
    parser.add_argument("--state", default="state", help="state directory (default: ./state)")
    parser.add_argument("--tcl-dir", default=None, help="override bundled tcl bootstrap dir")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    repl = sub.add_parser("repl", help="evaluate tcl interactively against a state dir")
    repl.add_argument("--nick", default="repl")
    repl.add_argument("--channel", default="#repl")
    repl.add_argument("--words", default=None, help="words file for [words]")
    repl.add_argument("--time-limit", type=int, default=5)

    audit = sub.add_parser("audit", help="check every saved proc: loads? runs? dead refs?")
    audit.add_argument("--json", action="store_true", help="full report as json")
    audit.add_argument("--no-run", action="store_true", help="skip calling zero-arg procs")
    audit.add_argument("--time-limit", type=int, default=2, help="seconds per proc call")

    sub.add_parser(
        "slack",
        help="run the slack bot over socket mode "
        "(needs SLACK_BOT_TOKEN, SLACK_APP_TOKEN; config via SMEGGDROP_* env)",
    )

    args = parser.parse_args(argv)
    if args.verbose:
        level = logging.DEBUG
    elif args.command == "slack":
        # running as a bot: the operator wants to see what is being
        # evaluated and by whom, not just failures
        level = logging.INFO
    else:
        level = logging.WARNING
    logging.basicConfig(level=level, format="%(levelname)s %(name)s: %(message)s")

    if args.command == "repl":
        return cmd_repl(args)
    if args.command == "slack":
        return cmd_slack(args)
    return cmd_audit(args)


def cmd_repl(args) -> int:
    try:
        import readline  # noqa: F401  (line editing / history)
    except ImportError:
        pass

    engine = Engine(
        FileStateStore(args.state),
        tcl_dir=args.tcl_dir,
        limits=Limits(eval_time_seconds=args.time_limit),
        words_file=args.words,
    )
    if engine.load_errors:
        print(f"({len(engine.load_errors)} state entries failed to load; -v for details)")
    print(f"smeggdrop repl — state: {args.state} — ^D to exit")
    try:
        while True:
            try:
                line = input("% ")
            except EOFError:
                print()
                break
            except KeyboardInterrupt:
                print()
                continue
            if not line.strip():
                continue
            result = engine.eval(
                EvalRequest(code=line, nick=args.nick, channel=args.channel, nicks=(args.nick,)),
                say=lambda text: print(f"[say] {text}"),
            )
            for warning in result.warnings:
                print(f"[warn] {warning}")
            if result.ok:
                if result.output:
                    print(result.output)
            else:
                print(f"error: {result.output}")
    finally:
        engine.close()
    return 0


def cmd_slack(args) -> int:
    from smeggdrop.hardening import apply_memory_limit
    from smeggdrop.platforms.slack import SlackConfig, run_socket_mode

    apply_memory_limit()
    cfg = SlackConfig.from_env()
    engine = Engine(
        FileStateStore(args.state),
        tcl_dir=args.tcl_dir,
        limits=Limits(eval_time_seconds=cfg.time_limit),
        words_file=cfg.words_file,
    )
    try:
        run_socket_mode(engine, cfg)
    finally:
        engine.close()
    return 0


def cmd_audit(args) -> int:
    store = FileStateStore(args.state)
    report = audit_state(
        store, tcl_dir=args.tcl_dir, run=not args.no_run, time_limit=args.time_limit
    )

    if args.json:
        json.dump(report.to_dict(), sys.stdout, indent=2)
        print()
    else:
        for p in report.procs:
            if not p.loaded:
                print(f"LOAD FAIL  {p.name}: {p.load_error}")
            elif p.broken_refs:
                print(f"BROKEN     {p.name}: references {', '.join(p.broken_refs)}")
            elif p.run_ok is False:
                print(f"RUN FAIL   {p.name}: {p.run_error}")
            elif p.unknown_refs:
                print(f"SUSPECT    {p.name}: unresolved {', '.join(p.unknown_refs)}")
        for name, err in report.var_load_errors.items():
            print(f"VAR FAIL   {name}: {err}")
        summary = report.summary()
        print(
            f"\n{summary['total']} procs: "
            f"{summary['load_failures']} load failures, "
            f"{summary['broken_refs']} with broken refs, "
            f"{summary['run_failures']}/{summary['ran']} run failures, "
            f"{summary['unknown_refs']} suspect, "
            f"{summary['var_load_failures']} var load failures"
        )

    return 1 if report.summary()["load_failures"] else 0


if __name__ == "__main__":
    sys.exit(main())

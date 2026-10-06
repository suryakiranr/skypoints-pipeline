"""Command line: ``skypoints deploy | put FILES... | run | dq | generate``."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

from skypoints import pipeline
from skypoints.generator import Defects, write_feed_files
from skypoints.snowflake_conn import connect, target_from_env


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="skypoints", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("deploy", help="create or upgrade all objects in the target schema")

    put = sub.add_parser("put", help="upload feed files to the inbound stage")
    put.add_argument("files", nargs="+", type=Path)

    sub.add_parser("run", help="ingest staged files and run the whole pipeline")
    sub.add_parser("dq", help="run the post-load data quality checks")

    gen = sub.add_parser("generate", help="write synthetic feed files")
    gen.add_argument("--members", type=int, default=1000)
    gen.add_argument("--timestamp", default=datetime.now().strftime("%Y%m%d%H%M%S"),
                     help="file timestamp, YYYYMMDDHHMMSS (default: now)")
    gen.add_argument("--seed", type=int, default=0)
    gen.add_argument("--reject-fraction", type=float, default=0.0)
    gen.add_argument("--warning-fraction", type=float, default=0.0)
    gen.add_argument("--out", type=Path, default=Path("data/generated"))

    args = parser.parse_args(argv)

    if args.command == "generate":
        paths = write_feed_files(
            args.out, args.members, datetime.strptime(args.timestamp, "%Y%m%d%H%M%S"),
            seed=args.seed,
            defects=Defects(args.reject_fraction, args.warning_fraction),
        )
        for path in paths:
            print(path)
        return 0

    target = target_from_env()
    with connect(target) as conn:
        if args.command == "deploy":
            count = pipeline.deploy(conn, target)
            print(f"deployed {count} statements into {target.database}.{target.schema}")
            return 0

        pipeline.use_schema(conn, target.schema)
        if args.command == "put":
            for staged in pipeline.put_files(conn, args.files):
                print(f"staged {staged.local_path} -> @STG_INBOUND/{staged.stage_path}")
            return 0
        if args.command == "run":
            summary = pipeline.run_pipeline(conn)
            print(json.dumps(summary, indent=2, default=str))
            return 1 if _has_dq_errors(summary) else 0
        if args.command == "dq":
            checks = pipeline.dq_checks(conn)
            for check in checks:
                flag = "FAIL" if check["failures"] else "ok  "
                name, severity = check["check_name"], check["severity"]
                print(f"{flag} {severity:<5} {name:<45} {check['failures']}")
            return 1 if any(c["failures"] and c["severity"] == "ERROR" for c in checks) else 0

    return 2


def _has_dq_errors(summary: dict) -> bool:
    return any(f.get("severity") == "ERROR" for f in summary.get("dq_failures") or [])


if __name__ == "__main__":
    sys.exit(main())

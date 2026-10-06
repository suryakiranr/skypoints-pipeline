"""Deploy the SQL, put feed files on the stage, run the pipeline, read results."""

from __future__ import annotations

import json
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any

from snowflake.connector import DictCursor, SnowflakeConnection

from skypoints.filenames import Feed, InvalidFileName, parse_file_name
from skypoints.snowflake_conn import Target
from skypoints.sql_script import render, split_statements

_REPO_SQL_DIR = Path(__file__).resolve().parents[2] / "sql"


def sql_dir() -> Path:
    """The sql/ directory: the repo copy in development, the packaged copy when installed."""
    if _REPO_SQL_DIR.is_dir():
        return _REPO_SQL_DIR
    return Path(str(resources.files("skypoints") / "sql"))


def sql_files() -> list[Path]:
    return sorted(sql_dir().glob("*.sql"))


def use_schema(conn: SnowflakeConnection, schema: str, *, create: bool = False) -> None:
    with conn.cursor() as cur:
        if create:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {_identifier(schema)}")
        cur.execute(f"USE SCHEMA {_identifier(schema)}")


def deploy(conn: SnowflakeConnection, target: Target) -> int:
    """Create or upgrade every object in the target schema. Idempotent."""
    use_schema(conn, target.schema, create=True)
    executed = 0
    with conn.cursor() as cur:
        for path in sql_files():
            sql = render(path.read_text(encoding="utf-8"), warehouse=_identifier(target.warehouse))
            for statement in split_statements(sql):
                cur.execute(statement)
                executed += 1
        cur.execute("CALL SP_ENSURE_COUNTRY_TABLES()")
    return executed


@dataclass(frozen=True)
class StagedFile:
    local_path: Path
    stage_path: str


def feed_for(path: Path) -> Feed:
    """Route a file to its stage prefix. A file whose name breaks the spec is
    still staged (by extension) so the pipeline records it as REJECTED rather
    than it silently never arriving."""
    try:
        return parse_file_name(path.name).feed
    except InvalidFileName:
        return Feed.REDEMPTION if path.suffix.lower() == ".json" else Feed.MEMBER


def put_files(conn: SnowflakeConnection, paths: list[Path]) -> list[StagedFile]:
    staged = []
    with conn.cursor() as cur:
        for path in paths:
            prefix = feed_for(path).stage_prefix
            uri = path.resolve().as_posix().replace("'", "\\'")
            cur.execute(
                f"PUT 'file://{uri}' @STG_INBOUND/{prefix}/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE"
            )
            staged.append(StagedFile(path, f"{prefix}/{path.name}"))
    return staged


def run_pipeline(conn: SnowflakeConnection) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute("CALL SP_RUN_PIPELINE(FALSE)")
        (summary,) = cur.fetchone()
    return json.loads(summary) if isinstance(summary, str) else summary


def dq_checks(conn: SnowflakeConnection) -> list[dict[str, Any]]:
    with conn.cursor(DictCursor) as cur:
        cur.execute("CALL SP_RUN_DQ_CHECKS()")
        return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]


def query(conn: SnowflakeConnection, sql: str, params: tuple | None = None) -> list[dict[str, Any]]:
    with conn.cursor(DictCursor) as cur:
        cur.execute(sql, params)
        return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]


def _identifier(name: str) -> str:
    """Accept only plain unquoted identifiers; they are spliced into SQL."""
    if not name.replace("_", "").replace("$", "").isalnum() or name[0].isdigit():
        raise ValueError(f"not a plain Snowflake identifier: {name!r}")
    return name

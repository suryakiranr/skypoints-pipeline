"""Snowflake connection from the environment. Credentials never live in the repo.

Either name a connection from ``~/.snowflake/connections.toml``:

    SNOWFLAKE_CONNECTION_NAME=skypoints

or set the parameters directly:

    SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, and one of SNOWFLAKE_PASSWORD /
    SNOWFLAKE_PRIVATE_KEY_FILE / SNOWFLAKE_AUTHENTICATOR (e.g. externalbrowser),
    plus optional SNOWFLAKE_ROLE.

Always required: SNOWFLAKE_WAREHOUSE and SNOWFLAKE_DATABASE. SNOWFLAKE_SCHEMA
defaults to SKYPOINTS.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

import snowflake.connector
from snowflake.connector import SnowflakeConnection

DEFAULT_SCHEMA = "SKYPOINTS"


class MissingSettings(RuntimeError):
    pass


@dataclass(frozen=True)
class Target:
    warehouse: str
    database: str
    schema: str


def target_from_env(env: Mapping[str, str] = os.environ) -> Target:
    missing = [k for k in ("SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_DATABASE") if not env.get(k)]
    if missing:
        raise MissingSettings(f"set {', '.join(missing)}")
    return Target(
        warehouse=env["SNOWFLAKE_WAREHOUSE"],
        database=env["SNOWFLAKE_DATABASE"],
        schema=env.get("SNOWFLAKE_SCHEMA") or DEFAULT_SCHEMA,
    )


def connection_params(env: Mapping[str, str] = os.environ) -> dict[str, str]:
    if env.get("SNOWFLAKE_CONNECTION_NAME"):
        return {"connection_name": env["SNOWFLAKE_CONNECTION_NAME"]}

    missing = [k for k in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER") if not env.get(k)]
    if missing:
        raise MissingSettings(f"set SNOWFLAKE_CONNECTION_NAME, or {', '.join(missing)}")

    params = {"account": env["SNOWFLAKE_ACCOUNT"], "user": env["SNOWFLAKE_USER"]}
    optional = {
        "SNOWFLAKE_PASSWORD": "password",
        "SNOWFLAKE_PRIVATE_KEY_FILE": "private_key_file",
        "SNOWFLAKE_AUTHENTICATOR": "authenticator",
        "SNOWFLAKE_ROLE": "role",
    }
    params.update({param: env[var] for var, param in optional.items() if env.get(var)})
    return params


def settings_present(env: Mapping[str, str] = os.environ) -> bool:
    try:
        connection_params(env)
        target_from_env(env)
    except MissingSettings:
        return False
    return True


def connect(target: Target, env: Mapping[str, str] = os.environ) -> SnowflakeConnection:
    """Connect with the target warehouse and database selected; the schema is
    selected by the caller (it may not exist yet)."""
    return snowflake.connector.connect(
        **connection_params(env),
        warehouse=target.warehouse,
        database=target.database,
    )

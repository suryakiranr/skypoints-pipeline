from pathlib import Path

import pytest

from skypoints.filenames import Feed
from skypoints.pipeline import _identifier, feed_for
from skypoints.snowflake_conn import (
    DEFAULT_SCHEMA,
    MissingSettings,
    connection_params,
    settings_present,
    target_from_env,
)


@pytest.mark.parametrize(
    ("name", "feed"),
    [
        ("SKYPOINTS_MEMBER_20240115_09000000.dat", Feed.MEMBER),
        ("SKYPOINTS_REDEMPTION_20240115_09000000.json", Feed.REDEMPTION),
        ("members_jan.dat", Feed.MEMBER),  # bad name still staged, then rejected in SQL
        ("partner_dump.json", Feed.REDEMPTION),
    ],
)
def test_feed_routing(name, feed):
    assert feed_for(Path(name)) is feed


def test_identifier_accepts_plain_names_only():
    assert _identifier("SKYPOINTS_IT_ab12") == "SKYPOINTS_IT_ab12"
    for bad in ["a;DROP", "x y", '"q"', "1abc"]:
        with pytest.raises(ValueError):
            _identifier(bad)


def test_named_connection_wins_over_parameters():
    env = {"SNOWFLAKE_CONNECTION_NAME": "dev", "SNOWFLAKE_ACCOUNT": "acct"}
    assert connection_params(env) == {"connection_name": "dev"}


def test_parameter_connection_picks_up_optional_settings():
    env = {
        "SNOWFLAKE_ACCOUNT": "acct",
        "SNOWFLAKE_USER": "me",
        "SNOWFLAKE_AUTHENTICATOR": "externalbrowser",
        "SNOWFLAKE_ROLE": "ETL",
    }
    assert connection_params(env) == {
        "account": "acct", "user": "me", "authenticator": "externalbrowser", "role": "ETL",
    }


def test_missing_settings_are_reported():
    with pytest.raises(MissingSettings, match="SNOWFLAKE_USER"):
        connection_params({"SNOWFLAKE_ACCOUNT": "acct"})
    with pytest.raises(MissingSettings, match="SNOWFLAKE_DATABASE"):
        target_from_env({"SNOWFLAKE_WAREHOUSE": "WH"})
    assert not settings_present({})


def test_schema_defaults():
    target = target_from_env({"SNOWFLAKE_WAREHOUSE": "WH", "SNOWFLAKE_DATABASE": "DB"})
    assert target.schema == DEFAULT_SCHEMA

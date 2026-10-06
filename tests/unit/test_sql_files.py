"""Static checks on sql/: they catch broken scripts before a deploy does."""

import re

import pytest

from skypoints.pipeline import sql_files
from skypoints.sql_script import render, split_statements

FILES = sql_files()


def statements(path):
    return split_statements(render(path.read_text(encoding="utf-8"), warehouse="WH"))


def test_scripts_exist_in_deploy_order():
    names = [p.name for p in FILES]
    assert names == sorted(names)
    assert names[0] == "00_foundation.sql"


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_every_script_splits_into_statements(path):
    assert statements(path)


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_dollar_quotes_are_balanced(path):
    assert path.read_text(encoding="utf-8").count("$$") % 2 == 0


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_objects_are_never_schema_qualified(path):
    """Unqualified names are what let tests deploy into a throwaway schema."""
    text = path.read_text(encoding="utf-8")
    assert not re.search(r"\bSKYPOINTS\.\w+", text)


def test_every_procedure_runs_with_callers_rights():
    for path in FILES:
        for statement in statements(path):
            if statement.upper().startswith("CREATE OR REPLACE PROCEDURE"):
                assert "EXECUTE AS CALLER" in statement, f"{path.name}: {statement[:60]}"


def test_every_called_procedure_is_defined():
    all_sql = "\n".join(p.read_text(encoding="utf-8") for p in FILES)
    defined = set(re.findall(r"CREATE OR REPLACE PROCEDURE (\w+)", all_sql))
    called = set(re.findall(r"CALL (\w+)\(", all_sql))
    assert called <= defined, called - defined


def test_every_stream_read_is_declared():
    all_sql = "\n".join(p.read_text(encoding="utf-8") for p in FILES)
    declared = set(re.findall(r"CREATE STREAM IF NOT EXISTS (\w+)", all_sql))
    read = set(re.findall(r"FROM (\w+_STREAM)\b", all_sql))
    assert read <= declared, read - declared

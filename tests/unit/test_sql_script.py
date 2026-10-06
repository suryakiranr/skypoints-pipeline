import pytest

from skypoints.sql_script import UnrenderedTemplate, render, split_statements


def test_splits_on_semicolons_and_drops_empty_statements():
    assert split_statements("SELECT 1;\n\nSELECT 2;;\n") == ["SELECT 1", "SELECT 2"]


def test_keeps_trailing_statement_without_semicolon():
    assert split_statements("SELECT 1;\nSELECT 2") == ["SELECT 1", "SELECT 2"]


def test_ignores_semicolons_inside_string_literals():
    sql = "SELECT 'a;b', 'it''s; fine', 'back\\';slash';SELECT 2;"

    assert split_statements(sql) == ["SELECT 'a;b', 'it''s; fine', 'back\\';slash'", "SELECT 2"]


def test_keeps_dollar_quoted_procedure_bodies_whole():
    sql = """CREATE PROCEDURE P() RETURNS VARCHAR LANGUAGE SQL AS
$$
BEGIN
  LET x VARCHAR := 'a;b';
  RETURN x;
END;
$$;
SELECT 1;"""

    statements = split_statements(sql)

    assert len(statements) == 2
    assert statements[0].endswith("END;\n$$")
    assert statements[1] == "SELECT 1"


def test_strips_comments_but_not_comment_markers_inside_strings():
    sql = """-- leading comment; with semicolon
SELECT '--not a comment' AS a /* block; comment */, 2; -- trailing
/* multi
   line; */
SELECT 3;"""

    assert split_statements(sql) == ["SELECT '--not a comment' AS a , 2", "SELECT 3"]


def test_comment_only_script_yields_nothing():
    assert split_statements("-- nothing here;\n/* or here; */\n") == []


def test_render_substitutes_placeholders():
    assert render("WAREHOUSE = {{ warehouse }}", warehouse="WH") == "WAREHOUSE = WH"


def test_render_refuses_to_leave_placeholders_behind():
    with pytest.raises(UnrenderedTemplate, match="warehouse"):
        render("WAREHOUSE = {{ warehouse }}")

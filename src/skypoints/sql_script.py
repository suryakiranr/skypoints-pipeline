"""Turn the files under ``sql/`` into executable statements.

The Snowflake connector executes one statement per call, so scripts are split
here. The splitter understands exactly what the scripts use: single-quoted
literals (with ``''`` and backslash escapes), ``$$``-quoted procedure bodies,
and ``--`` / ``/* */`` comments.
"""

from __future__ import annotations

import re

_PLACEHOLDER = re.compile(r"\{\{\s*(\w+)\s*\}\}")


class UnrenderedTemplate(ValueError):
    pass


def render(sql: str, **values: str) -> str:
    """Replace ``{{ name }}`` placeholders; fail on any placeholder left unfilled."""
    missing = sorted({name for name in _PLACEHOLDER.findall(sql) if name not in values})
    if missing:
        raise UnrenderedTemplate(f"no value for placeholder(s): {', '.join(missing)}")
    return _PLACEHOLDER.sub(lambda m: values[m.group(1)], sql)


def split_statements(sql: str) -> list[str]:
    statements: list[str] = []
    current: list[str] = []
    i, n = 0, len(sql)

    def flush() -> None:
        statement = "".join(current).strip()
        if statement:
            statements.append(statement)
        current.clear()

    while i < n:
        ch = sql[i]
        if sql.startswith("$$", i):
            end = sql.find("$$", i + 2)
            end = n if end == -1 else end + 2
            current.append(sql[i:end])
            i = end
        elif ch == "'":
            j = i + 1
            while j < n:
                if sql[j] == "\\":
                    j += 2
                elif sql.startswith("''", j):
                    j += 2
                elif sql[j] == "'":
                    j += 1
                    break
                else:
                    j += 1
            current.append(sql[i:j])
            i = j
        elif sql.startswith("--", i):
            end = sql.find("\n", i)
            i = n if end == -1 else end
        elif sql.startswith("/*", i):
            end = sql.find("*/", i + 2)
            i = n if end == -1 else end + 2
        elif ch == ";":
            flush()
            i += 1
        else:
            current.append(ch)
            i += 1

    flush()
    return statements

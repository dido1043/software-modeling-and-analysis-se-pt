#!/usr/bin/env python3
"""
Static consistency check of the T-SQL scripts in src/ - no database needed.

What is checked
  1. Every two- or three-part object name used after FROM / JOIN / APPLY /
     INSERT INTO / UPDATE / MERGE / DELETE FROM / REFERENCES / EXEC resolves to
     a table, view, function or procedure created in the right database
     (HBOMaxOLTP for src/oltp and for "HBOMaxOLTP." names, HBOMaxDW otherwise).
  2. Every column in an INSERT INTO <table> (<column list>) exists in <table>.
  3. Every alias.column reference resolves: within a GO batch, each alias is
     bound to the tables it is declared for ("FROM acct.Profile AS p"), and the
     column must exist in at least one of them. Views, CTEs, derived tables and
     temp tables are not checked.

Usage
    python tools/check_sql_consistency.py            # defaults: src/
    python tools/check_sql_consistency.py SRC_DIR

Exit code 0 when everything resolves, 1 otherwise. Standard library only.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "src"

KEYWORDS = {
    "AS", "ON", "WHERE", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "JOIN", "GROUP", "ORDER",
    "WITH", "SET", "OUTPUT", "WHEN", "USING", "UNION", "SELECT", "VALUES", "HAVING", "OPTION", "APPLY",
}


def strip_comments(t):
    """Remove comments and blank out string literals in one left-to-right pass,
    so that '--' inside a string is not taken for a comment."""
    def repl(m):
        s = m.group(0)
        if s.startswith("/*"):
            return " " * 0 + "\n" * s.count("\n")
        if s.startswith("--"):
            return " "
        return "''"
    return re.sub(r"/\*.*?\*/|--[^\n]*|N?'(?:[^']|'')*'", repl, t, flags=re.S)


def norm(name):
    return ".".join(p.strip("[]").lower() for p in name.split("."))


def body_after(text, i):
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    return ""


def split_commas(body):
    out, depth, cur = [], 0, ""
    for ch in body:
        depth += ch == "("
        depth -= ch == ")"
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    return out + ([cur.strip()] if cur.strip() else [])


def database_of(path):
    return "oltp" if "oltp" in path.parts else "dw"


def collect(files):
    tables, objects = {"oltp": {}, "dw": {}}, {"oltp": set(), "dw": set()}
    for f in files:
        db, txt = database_of(f), strip_comments(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"CREATE\s+TABLE\s+([\[\]\w]+\.[\[\]\w]+)\s*\(", txt, re.I):
            cols = set()
            for part in split_commas(body_after(txt, m.end() - 1)):
                first = part.split()[0].strip("[]").upper() if part.split() else ""
                if first in ("CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "INDEX"):
                    continue
                cols.add(part.split()[0].strip("[]").lower())
            tables[db][norm(m.group(1))] = cols
            objects[db].add(norm(m.group(1)))
        for m in re.finditer(r"CREATE\s+(?:OR\s+ALTER\s+)?(?:VIEW|FUNCTION|PROCEDURE|PROC|TRIGGER)\s+([\[\]\w]+\.[\[\]\w]+)",
                             txt, re.I):
            objects[db].add(norm(m.group(1)))
    return tables, objects


def resolve(name, db):
    parts = norm(name).split(".")
    if len(parts) == 3:
        return {"hbomaxoltp": "oltp", "hbomaxdw": "dw"}.get(parts[0]), ".".join(parts[1:])
    return db, ".".join(parts)


def check(files, tables, objects):
    problems = []
    ref_re = re.compile(r"\b(?:FROM|JOIN|APPLY|INTO|UPDATE|MERGE|REFERENCES|EXEC(?:UTE)?|TABLE)\s+"
                        r"((?:[\[\]\w]+\.){1,2}[\[\]\w]+)", re.I)
    alias_re = re.compile(r"\b(?:FROM|JOIN|UPDATE|MERGE|INTO)\s+((?:[\[\]\w#@]+\.){0,2}[\[\]\w#@]+)"
                          r"(?:\s+AS)?\s+(\w+)", re.I)
    for f in files:
        db = database_of(f)
        txt = strip_comments(f.read_text(encoding="utf-8"))
        for b_no, batch in enumerate(re.split(r"^\s*GO\s*$", txt, flags=re.M | re.I)):
            line0 = txt[:txt.find(batch)].count("\n") if batch else 0
            # 1. object references
            for m in ref_re.finditer(batch):
                rdb, obj = resolve(m.group(1), db)
                if obj.startswith(("sys.", "dbo.ufn_seedhash")) or rdb is None:
                    continue
                if obj not in objects[rdb]:
                    problems.append(f"{f.name}:{line0 + batch[:m.start()].count(chr(10)) + 1}: "
                                    f"unknown object {m.group(1)}")
            # 2. INSERT column lists
            for m in re.finditer(r"INSERT\s+INTO\s+((?:[\[\]\w]+\.){1,2}[\[\]\w]+)\s*\(", batch, re.I):
                rdb, obj = resolve(m.group(1), db)
                if rdb is None or obj not in tables[rdb]:
                    continue
                for col in split_commas(body_after(batch, m.end() - 1)):
                    c = col.strip().strip("[]").lower()
                    if c and c not in tables[rdb][obj]:
                        problems.append(f"{f.name}:{line0 + batch[:m.start()].count(chr(10)) + 1}: "
                                        f"INSERT INTO {obj}: no column {col.strip()}")
            # 3. alias.column references
            aliases = {}
            for m in alias_re.finditer(batch):
                alias = m.group(2)
                if alias.upper() in KEYWORDS:
                    continue
                rdb, obj = resolve(m.group(1), db) if "." in m.group(1) else (None, None)
                if rdb and obj in tables[rdb]:
                    aliases.setdefault(alias.lower(), []).append(tables[rdb][obj])
                else:
                    aliases.setdefault(alias.lower(), []).append(None)    # view / function: skip
            for m in re.finditer(r"\)\s*(?:AS\s+)?(\w+)(?=\s*(?:\(|ON\b|WHERE\b|INNER\b|LEFT\b|CROSS\b|OUTER\b|JOIN\b|$|\)|,))",
                                 batch, re.I | re.M):
                if m.group(1).upper() not in KEYWORDS:      # derived table / APPLY alias
                    aliases.setdefault(m.group(1).lower(), []).append(None)
            for m in re.finditer(r"\b(\w+)\.(\[?\w+\]?)\b", batch):
                a, col = m.group(1).lower(), m.group(2).strip("[]").lower()
                if a not in aliases or None in aliases[a]:
                    continue
                if not any(col in cols for cols in aliases[a]):
                    problems.append(f"{f.name}:{line0 + batch[:m.start()].count(chr(10)) + 1}: "
                                    f"{m.group(0)} - no such column")
    return problems


if __name__ == "__main__":
    files = sorted(SRC.glob("oltp/*.sql")) + sorted(SRC.glob("dw/*.sql"))
    tables, objects = collect(files)
    problems = check(files, tables, objects)
    for p in problems:
        print(p)
    print(f"{len(files)} files, {sum(len(t) for t in tables.values())} tables, "
          f"{sum(len(o) for o in objects.values())} objects - "
          + ("OK" if not problems else f"{len(problems)} problem(s)"))
    sys.exit(1 if problems else 0)

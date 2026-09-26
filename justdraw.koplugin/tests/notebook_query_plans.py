#!/usr/bin/env python3
"""Check that every gallery order is served by an index (Task 9.1).

KOReader's lua-ljsqlite3 returns no rows for EXPLAIN QUERY PLAN, so the plans
are read here, with Python's sqlite3, from the library that
tests/notebook_repository_native.lua leaves behind with JUSTDRAW_KEEP_DB=1.
The statements mirror Repository.SORTS and the three scopes of
Repository:listNotebookPage; a plan that sorts in a temporary B-tree would
make every gallery page cost the whole library.

    python3 tests/notebook_query_plans.py /tmp/jd-repo-native-...-fresh.sqlite3
"""
import sqlite3
import sys

SORTS = {
    "recent": "updated_at DESC, id DESC",
    "oldest": "updated_at ASC, id ASC",
    "title_asc": "title COLLATE NOCASE ASC, id ASC",
    "title_desc": "title COLLATE NOCASE DESC, id DESC",
}
SCOPES = {
    "all": "",
    "root": " AND folder_id IS NULL",
    "folder": " AND folder_id = 1",
}


def main(path):
    conn = sqlite3.connect(path)
    failed = 0
    for sort, order in SORTS.items():
        for scope, extra in SCOPES.items():
            sql = ("SELECT id FROM notebooks WHERE deleted_at IS NULL AND copy_state IS NULL"
                   + extra + " ORDER BY " + order + " LIMIT 51")
            plan = " | ".join(row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + sql))
            ok = "TEMP B-TREE" not in plan
            failed += 0 if ok else 1
            print(("OK  " if ok else "FAIL") + " %-10s %-6s %s" % (sort, scope, plan))
    folders = " | ".join(row[3] for row in conn.execute(
        "EXPLAIN QUERY PLAN SELECT id FROM notebook_folders WHERE deleted_at IS NULL "
        "ORDER BY name COLLATE NOCASE, id LIMIT 51"))
    ok = "TEMP B-TREE" not in folders
    failed += 0 if ok else 1
    print(("OK  " if ok else "FAIL") + " folders           " + folders)
    print("QUERY_PLANS_OK" if failed == 0 else "%d plan(s) sort in a temporary B-tree" % failed)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

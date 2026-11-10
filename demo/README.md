# Practice with the demo

Run `:GripStart` for the Softrear investigation. It recreates disposable data,
opens the bundled notebook, and places the cursor in its first SQL block. Press
`<C-CR>` to run that block. Search the notebook for `Daily practice` when you want
to try a small task loop instead of reading the whole investigation.

```text
find -> inspect -> filter -> edit -> review SQL -> undo / apply
```

The examples use default keys. `?` shows the configured keys for your current
pane. The commands and staging behavior stay the same when you use your own
database, subject to its permissions.

| Local clients | Available practice |
| --- | --- |
| `sqlite3` | The 35-roll investigation, the shared summary view, and daily grid tasks. |
| `duckdb` | The full 505-roll investigation, the summary view, a reporting schema, and a SQL macro. |
| Both clients | The DuckDB practice plus the attached supplier database and cross-database joins. |

The SQLite fallback has a flat object list. DuckDB macros are called in SQL;
Dadbod Grip does not list them as PostgreSQL functions. DuckDB file partitions
are not PostgreSQL child-table partitions.

## PostgreSQL schema lab

This optional lab requires a local PostgreSQL server and `psql`. It is separate
from `:GripStart`. Use a new disposable database you create for this exercise;
the lab creates a fresh `grip_demo` schema and rejects an existing schema with
that name. It does not change roles, extensions, grants, or server settings.

From a checkout of this plugin, run:

```sh
createdb grip_demo
psql -X --set ON_ERROR_STOP=1 --dbname=grip_demo -f demo/softrear_postgres.sql
```

Then connect Dadbod Grip to that local database:

```vim
:GripConnect postgresql:///grip_demo
```

In the schema sidebar, expand `grip_demo` with `l`. Use `gb` from another pane
when you need to focus schema again. The partition children
start collapsed; `l` on the table reveals its Partitions group, and `l` on that
group reveals children. `h` folds or returns to the parent. `L` expands all
schema and partition levels; `H` collapses them.

```text
grip_demo
  Tables
    incidents
      Partitions (2)
        incidents_2026
          Partitions (2)
            incidents_2026_01
            incidents_2026_later
        incidents_default
  Views
    open_incidents
  Functions
    severity_label(value integer)
```

Press `/`, search for `incidents_2026_01`, and confirm. Search reveals the leaf
inside its closed ancestors. Enter opens that child table. Press `gb` to return
to schema, then `F` to clear its search and restore the previous folds.

Open SQL with `2` from schema. Run these statements separately to compare the
parent with a single partition:

```sql
SELECT COUNT(*) AS all_incidents FROM grip_demo.incidents;
```

```sql
SELECT COUNT(*) AS january_incidents FROM grip_demo.incidents_2026_01;
```

The counts are four across all partitions and two in the January child. Open the `open_incidents` view to see the two unresolved incidents. Enter on
`severity_label(value integer)` opens its definition for inspection, without
executing it. Call the function explicitly from SQL:

```sql
SELECT grip_demo.severity_label(8) AS priority;
```

The result is `high`. The lab uses actual PostgreSQL catalog relationships, so
its partition tree is available only for PostgreSQL connections. See the
[PostgreSQL partitioning documentation](https://www.postgresql.org/docs/current/ddl-partitioning.html)
for parent-query behavior.

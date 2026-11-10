# Engine timing

`setup({ engine_timing = true })` enables collection for the main result SELECT,
refresh, and actual database write execution. The default is `false`. `db.query(sql, url, opts)` and
`db.execute(sql, url, opts)` also accept `{ engine_timing = true }` per call.
COUNT, schema, primary-key, and other catalog calls are not opted in by the grid.
Collection is independent of the result timing display preference.
Successful write/reload results retain `Write engine` separately from the
reload SELECT's `Engine` value. Both belong to their immutable result rows;
metadata, FK navigation, and later unrelated refreshes inherit neither write
duration. `show_result_time = false` hides all engine/client footer timings
without changing collection. Zen's `show_hints` is independent.

The `Engine` label means **DuckDB profiler latency**, using its JSON `latency`
metric, in seconds, converted to milliseconds. It measures the adapter statement
in the same DuckDB process that returns its normal result. Query results retain
the existing nested-value conversion wrapper, so that wrapper belongs to the
measured statement. Attachment setup happens before profiling is enabled.
This value is separate from the external client clock, cumulative operator CPU,
and any remote database execution time when DuckDB reads an attachment.
Profiling adds overhead, so these values are diagnostic observations.
The first eligible call runs a synthetic in-memory capability probe with no
init file, attachment, extension, or user SQL. The probe validates JSON/ALL
support and is cached by executable path, size, and modification time. That
one-time probe belongs to the first client clock. Unsupported/unavailable
capabilities preserve the legacy query path; cancellation or timeout during
preflight aborts the request before user SQL starts.

## Support matrix

| Adapter | Collection in this implementation | Reason and follow-up boundary |
| --- | --- | --- |
| DuckDB | Eligible single-statement SELECTs and `db.execute` writes | JSON profiling, `profiling_coverage = 'ALL'`, exact submitted-statement correlation. Locally exercised with DuckDB 1.5.5. |
| DuckDB batches and session controls | Unsupported | The profiling file retains the last profiled statement, which cannot represent an entire batch. Existing execution runs once. |
| PostgreSQL | Unsupported | No collector is implemented. `EXPLAIN ANALYZE` is a separate execution with side effects and is never run automatically. |
| MySQL/MariaDB | Unsupported | No collector is implemented. A future Performance Schema collector needs available timed events and exact same-session event correlation for each engine. |
| SQL Server | Unsupported | No collector is implemented. Same-run `SET STATISTICS TIME` is a possible future path requiring tested parsing and batch attribution. It does not require SHOWPLAN permission. |
| SQLite | Unsupported | CLI `.timer` is deliberately not collected under this DuckDB profiler contract. |

The facade returns `result.engine_timing.status` as `available`, `unsupported`,
or `unavailable`. Only `available` has numeric `elapsed_ms`. DuckDB identifies
`source = 'duckdb_profile'`, `adapter = 'duckdb'`, and `scope = 'statement'`.
Absent values include a machine-readable reason, such as `multiple_statements`,
`profile_missing`, `statement_mismatch`, or `invalid_duration`. Errors retain the
existing `(nil, error)` contract. Default calls do not add timing metadata.

The eligibility check is intentionally conservative. Semicolons in quoted
strings, dollar-quoted text, and comments do not form a batch; unsupported
syntax and session/profiling commands run normally with unsupported timing.
The complete profile query name must match the submitted adapter payload apart
from outer whitespace. Eligibility only controls collection: unsupported syntax,
batches, capability failures, and setup failures retain the original conversion
and compatibility fallback. A batch can need a failed wrapper parse before its
original SQL runs once, just as before. An actually enabled profile disables
compatibility retry, including errors caused by the SELECT wrapper.
A profile for a final batch statement is never accepted
as a total, and an absent or invalid value is never replaced with zero.

Every profile lives in a per-call private temporary directory created with mode
0700. The profile and directory are removed after success, query error, timeout,
interruption, or parsing failure. Profile processes opt in to termination and
bounded reaping after an interrupted wait; their child exits before ordinary
cleanup. The default CLI runner contract is unchanged. Late profiler output cannot recreate that
removed directory. Only numeric metadata and fixed status/reason strings reach
the result; raw SQL/profile contents are not copied into timing history or UI.
No privileges are added, no persistent database configuration changes, no
automatic EXPLAIN ANALYZE, and no retries are introduced. A failed batch can
still have partial effects according to its ordinary transaction semantics.

## Upstream contracts

- [DuckDB profiling settings](https://duckdb.org/docs/current/dev/profiling): JSON format and `SELECT`/`ALL` coverage.
- [DuckDB metrics](https://duckdb.org/docs/current/dev/metrics): LATENCY is elapsed whole-query time in seconds; CPU_TIME is cumulative operator timing.
- [DuckDB profiling output](https://duckdb.org/docs/current/configuration/pragmas#profiling-output): a new statement overwrites the profiling file.
- [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html): ANALYZE executes the statement and its side effects.
- [MySQL statement events](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-events-statements-current-table.html): thread/event identity and nullable timing from untimed instruments.
- [MariaDB statement events](https://mariadb.com/docs/server/reference/system-tables/performance-schema/performance-schema-tables/performance-schema-events_statements_current-table): thread/event identity and nullable timer values.
- [SQL Server STATISTICS TIME](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-statistics-time-transact-sql): compilation/execution CPU and elapsed times, with ordinary statement permissions.
- [SQLite CLI](https://sqlite.org/cli.html): shell timing controls.

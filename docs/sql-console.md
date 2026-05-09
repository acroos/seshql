# SQL Console

`/sql_console` is a direct read-only SQL interface to the SeshQL database.
Paste a query, get a result table.

## Safety rails

The console is intentionally narrow — it executes against your
production-ish dev database, so it enforces:

- **Read-only.** Only `SELECT` and `WITH` queries run. Anything matching
  `INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|COPY` (or
  `EXEC`, `LOAD DATA`, `INTO OUTFILE`) is rejected before it hits Postgres.
- **One statement at a time.** Multiple statements separated by `;` are
  rejected.
- **Row cap.** Every query is wrapped with `LIMIT 500`. If your query has its
  own `LIMIT N`, it's clamped down to 500 max.
- **Statement timeout.** A 10-second `statement_timeout` is set per query.
  Long aggregations get killed rather than hanging the page.

If you need to bypass any of these (e.g., to write to the DB), open a
`bin/rails dbconsole` instead.

## Example queries

The page sidebar lists ~14 ready-to-run examples covering the queries we've
found most useful — token usage by tool, cache hit rates by model, peak
context window utilization, % of session tokens spent on `git`/`gh`, etc.
Click one to load it into the editor; tweak from there.

The full list lives in
[`app/controllers/sql_console_controller.rb`](../app/controllers/sql_console_controller.rb)
under `EXAMPLE_QUERIES`. Add or edit entries there to share queries with
your future self.

## Schema reference

The right side of the console shows the available tables and their columns.
The same reference is in [`docs/schema.md`](schema.md) if you want it
outside the app.

## Tips

- Use the [example queries](../app/controllers/sql_console_controller.rb) as
  templates — most analyses start by joining
  `sessions ↔ messages ↔ assistant_messages ↔ content_blocks` and
  summing the four token columns.
- Tool inputs are stored as JSONB in `content_blocks.tool_input`, so you can
  query things like `tool_input->>'command'` or
  `tool_input ? 'offset'`.
- If a query you care about is reusable, save it as a dashboard panel — see
  [Dashboards](dashboards.md).

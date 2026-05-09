# Dashboards

`/dashboards` lets you save SQL queries as reusable panels and group them
into named dashboards. The home page (`/`) redirects to the dashboards
index, so this is the default landing surface.

## Concepts

- **Dashboard** — a named collection of panels.
- **Panel** — one SQL query plus a render mode (table, single number, etc.).
  Panels belong to exactly one dashboard.

## Creating a dashboard

1. Visit `/dashboards`.
2. Click **New dashboard**, give it a name, save.
3. From the dashboard's show page, click **New panel**.
4. Paste in a SELECT (the same rules as the [SQL Console](sql-console.md)
   apply — read-only, single statement, capped at 500 rows).
5. Pick a display mode and save.

The query runs on every page load, so panels reflect the current state of
the database. There's no caching layer — if you have an expensive query,
keep it tight or precompute upstream.

## Editing and deleting

Each panel has edit/delete actions on the dashboard show page. Deleting a
dashboard cascades to its panels.

## Suggested starter panels

Good first dashboards to copy from the [SQL console examples](sql-console.md):

- **Daily token usage** — single chart of tokens per day for the last 30 days.
- **Top sessions by token cost** — table of the most expensive sessions.
- **Tool usage frequency** — table of tool calls grouped by tool name.
- **Cache hit rate by model** — single number per model showing how much of
  your input tokens hit the prompt cache.

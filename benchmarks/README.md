# Large-list measurements

Run `mise run benchmark` from the repository root. The task builds ReleaseSafe and
runs five independent processes per size (10,000, 100,000, 1,000,000). Each process
generates the same long paths, Unicode, repeated basename families and distinct
values. It measures the production ingestion, filter, history hook (100 recent
entries near the tail) and 20 navigation renders. Timings are milliseconds;
`rss_kib` is process peak resident memory from GNU time. p95 uses nearest rank.

`baseline.json` records the unoptimized implementation at ca24613 plus this
harness. SDL uses the offscreen backend: render measurements include text/texture
creation and present, but exclude compositor, keyboard dispatch and physical
display latency. They cannot establish the desktop typing/Escape p95 <50 ms goal.
The generated dataset is in memory; ingest excludes pipe transport and producer
scheduling. History is invoked explicitly even though disabled in default config.

Verification for the baseline commit: `mise run test`,
`mise run build:release-safe`, `mise run benchmark`, `git diff --check`.

`viewport.json` repeats the baseline after removing all-item text measurement.
`mise run test:ui` also writes layout captures under `benchmarks/visual/` for
100%, 150% and 200%. These use SDL render targets at physical pixel dimensions;
they exercise the production drawing path, but do not validate compositor DPI
notifications or real monitor placement. Loading, long rows/previews, paging and
query-tail clipping were inspected at all three scales. The embedded font lacks
Japanese glyphs (tofu boxes); UTF-8 data is preserved. Latte contrast is addressed
in the final theme commit. Unit tests, ReleaseSafe build and confirmation checks
passed with the viewport changes.

The ownership commit passed 85 unit tests, ReleaseSafe and `test:ui`. Added
allocation-failure injection across parsing and item transfer, 10,000-line
ordered delivery, byte-limit and line-limit backpressure, and cancellation with
a full queue and an open producer pipe. `ownership.json` repeats internal
measurements; its ingest adapter excludes the queue, so it does not quantify the
removed producer-to-item copy or pipeline peak memory.

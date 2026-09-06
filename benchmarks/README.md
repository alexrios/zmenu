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

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

`environment.json` records the workstation used for the baseline. Texture counts
were remeasured on `c4ed9f2` with `baseline-texture-counter.patch` applied;
`baseline-textures.json` records those counts. `final.json` and `wayland.json`
retain the completed implementation's offscreen and native-backend results.
Intermediate measurements remain available in the implementation commits.

The ingestion adapter excludes the shared stdin queue, so its timings do not
quantify the removed producer-to-item copy or pipeline peak memory.
`candidates_examined` is an item count, not milliseconds. History runs
synchronously outside the cooperative search budget and is disabled by default.

Use `mise run --skip-tools benchmark` to avoid installing missing global mise
tools. To measure the native backend, run
`ZMENU_BENCH_VIDEO=wayland mise run --skip-tools benchmark`.
`mise run test:ui` runs event checks and generates ignored layout captures under
`benchmarks/visual/`. Captures use SDL render targets at simulated pixel scales;
they do not validate compositor DPI notifications or physical display latency.

## Final acceptance

`final.json` is the final ReleaseSafe offscreen run. Values below are p95 in
milliseconds; RSS is the maximum process resident memory sampled by GNU time.

| Items | Ingest before / after | Fresh fuzzy query before / after | History before / after | Navigation render before / after |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 219.67 / 1.15 | 0.45 / 0.58 | 16.18 / 0.44 | 4.43 / 2.89 |
| 100,000 | 2,417.96 / 10.00 | 4.25 / 5.75 | 268.65 / 5.98 | 4.22 / 3.00 |
| 1,000,000 | 37,681.64 / 98.73 | 44.98 / 56.16 | 2,151.88 / 52.33 | 7.59 / 2.87 |

The clock checks add cost to a fresh full scan; cooperative slices and candidate
reuse improve responsiveness rather than making every whole query faster.
With 1 million items, RSS p95 is 307.8 MiB versus 320.6 MiB originally. These
process peaks include SDL and the in-memory collection, but exclude real pipe
transport. After selected previews also invert their colors, the final count
is 116 textures per 20 navigation renders, versus 1,222 originally.

`wayland.json` repeats the benchmark on the actual Wayland backend:

| Items | SDL input to first present | SDL input to completed-results present | Escape dispatch |
| ---: | ---: | ---: | ---: |
| 10,000 | 1.88 ms | 3.90 ms | 0.003 ms |
| 100,000 | 3.12 ms | 16.38 ms | 0.007 ms |
| 1,000,000 | 3.41 ms | 71.23 ms | 0.007 ms |

Each process injects 20 edits through SDL, alternating a match and no-match
query, and 20 Escape events. `input_first_frame` ends at the first completed
SDL `present` call after an edit; it can still show previous results with the
searching label. `input_results_frame` waits for the current query to finish.
`escape_dispatch` ends when the event handler requests exit; it excludes reader
cancellation and window teardown. These are application-boundary measurements,
not physical keyboard-to-display latency or compositor presentation feedback.
The <50 ms target is therefore **not fully accepted**: completed results exceed
it at 1 million items, history can exceed it when enabled, and physical display
latency/full Escape teardown remain unmeasured.

Validation completed:

- 88 unit tests, including independent matching/ranking oracles, allocation
  failures, queue bounds, cancellation and ordered delivery.
- ReleaseSafe native build, history-enabled tests/build, and Windows x86_64 GNU
  ReleaseSafe cross-build. Windows execution was not available.
- Real event-dispatch checks for empty Enter, recovery, partial confirmation,
  duplicate identity, edit/navigation barriers, immediate Escape and cache
  invalidation/eviction. The live Wayland open-pipe confirmation exited
  successfully and wrote `confirmed-stream` before the producer closed stdin. Wayland refused explicit
  window placement; the existing compositor-controlled fallback was used.
- Rendered inspection of loading, partial results, selection, long paths,
  previews, query tails, footer and paging at simulated 100%, 150% and 200%.
  All eight themes were inspected. Captures are in `benchmarks/visual/` and
  regenerate with `mise run test:ui`. Physical monitor DPI transitions and
  multi-monitor placement remain unverified; Wayland refused explicit placement
  and used the existing compositor-controlled fallback. The embedded Crimson
  Pro font displays missing-glyph boxes for Japanese text while preserving data.

One initial Wayland benchmark process exited 134 at 100,000 items. The original
runner discarded its stderr; the cause is unknown. Twenty same-size repetitions,
a complete 15-process measurement run, and 50 alternating-size repetitions then
passed (85 processes). This is not a diagnosed or fixed defect. The runner now
preserves stderr in `benchmarks/failure-<backend>-<size>.log` on failure.

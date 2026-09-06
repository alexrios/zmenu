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

`incremental.json` includes whole-query time, per-slice time and extension work.
`candidates_examined` is an item count, not milliseconds. For 1 million items,
the fuzzy query took 56.6 ms p95 overall while slices were 4.0 ms p95; its extension
visited 232,363 candidates. Total completion exceeds 50 ms for this query and
must not be confused with input/Escape dispatch latency. The SDL event checks
cover edits separated by navigation, duplicate identities, pending Enter,
Escape bypass and confirmation in the real run loop while a pipe stays open.
Matching tests compare fuzzy/prefix/exact against an independent reference,
including abandoned queries and arrivals during scans. Unit tests, ReleaseSafe
and `test:ui` passed. Real compositor input-to-present p95 remains unmeasured.

`history.json` measures stable rank distribution. At 1 million matches, history
p95 fell from 2,151.9 ms to 62.7 ms. This hook is synchronous and remains outside
the cooperative matching budget; enabling history can exceed the 50 ms response
target. An independent O(N*H) oracle checks duplicate ranks and stable order;
allocation failures leave the original order intact and scratch capacity is
reused. Unit tests and ReleaseSafe were checked with history both disabled and
enabled; offscreen UI checks used the default configuration.

Texture counts were remeasured on `c4ed9f2` with only the instrumentation in
`baseline-texture-counter.patch`; `baseline-textures.json` records 1,222 texture
creations per 20 navigation renders for every input size. `before-cache.json`
records 382 after the viewport changes, and `cache.json` records 97 with visible
row caching. At 1 million items, render p95 is 2.78 ms versus 7.59 ms originally;
short-run timing variance remains, so texture counts are the clearer evidence
for the cache itself. UI tests check identical-frame reuse, selection-only
updates, font generation invalidation and eviction after an empty result.

When global mise tools are still missing, use `mise run --skip-tools benchmark`
(or `MISE_TASK_RUN_AUTO_INSTALL=false`) to use installed tools without automatic
installation. One measurement attempt was stopped after global auto-install
started unrelated Cargo tools and installed pass-cli 2.3.3; measured runs used
the existing Zig 0.16.0 with auto-install disabled afterward.

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
latency/full Escape teardown remain unmeasured. Run the native measurements with
`ZMENU_BENCH_VIDEO=wayland mise run --skip-tools benchmark`.

Validation completed:

- 88 unit tests, including independent matching/ranking oracles, allocation
  failures, queue bounds, cancellation and ordered delivery.
- ReleaseSafe native build, history-enabled tests/build, and Windows x86_64 GNU
  ReleaseSafe cross-build. Windows execution was not available.
- Real event-dispatch checks for empty Enter, recovery, partial confirmation,
  duplicate identity, edit/navigation barriers, immediate Escape and cache
  invalidation/eviction. The live Wayland open-pipe confirmation succeeded
  (`wayland-smoke.json`).
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

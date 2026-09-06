"""Deterministic internal timings. No desktop input-to-present latency claims."""
import json
import math
import os
import platform
import statistics
import subprocess
from pathlib import Path

video = os.environ.get("ZMENU_BENCH_VIDEO", "offscreen")
results = {"environment": {"platform": platform.platform(), "cpu": platform.processor(),
           "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
           "mode": "ReleaseSafe", "video": video, "repetitions": 5}, "sizes": {}}
for size in (10_000, 100_000, 1_000_000):
    samples = {}
    for _ in range(5):
        run = subprocess.run(["/usr/bin/time", "-f", "BENCH rss_kib %M", "zig-out/bin/large-list-bench", str(size)],
                             env={**os.environ, "SDL_VIDEODRIVER": video}, capture_output=True, text=True)
        if run.returncode:
            failure = Path(f"benchmarks/failure-{video}-{size}.log")
            failure.write_text(run.stderr)
            raise SystemExit(f"Benchmark exited {run.returncode}; evidence: {failure}")
        for line in run.stderr.splitlines():
            if line.startswith("BENCH "):
                _, name, value = line.split()
                samples.setdefault(name, []).append(float(value))
    results["sizes"][str(size)] = {name: {"p50": statistics.median(values),
        "p95": sorted(values)[math.ceil(.95 * len(values)) - 1]} for name, values in samples.items()}
print(json.dumps(results, indent=2))

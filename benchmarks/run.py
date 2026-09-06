"""Deterministic internal timings. No desktop input-to-present latency claims."""
import json
import math
import os
import platform
import statistics
import subprocess

results = {"environment": {"platform": platform.platform(), "cpu": platform.processor(),
           "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
           "mode": "ReleaseSafe", "video": "offscreen", "repetitions": 5}, "sizes": {}}
for size in (10_000, 100_000, 1_000_000):
    samples = {}
    for _ in range(5):
        run = subprocess.run(["/usr/bin/time", "-f", "BENCH rss_kib %M", "zig-out/bin/large-list-bench", str(size)],
                             env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, capture_output=True, text=True, check=True)
        for line in run.stderr.splitlines():
            if line.startswith("BENCH "):
                _, name, value = line.split()
                samples.setdefault(name, []).append(float(value))
    results["sizes"][str(size)] = {name: {"p50": statistics.median(values),
        "p95": sorted(values)[math.ceil(.95 * len(values)) - 1]} for name, values in samples.items()}
print(json.dumps(results, indent=2))

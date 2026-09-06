import os
import subprocess

result = subprocess.run(["zig-out/bin/large-list-bench", "check-confirm"],
    env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, capture_output=True, text=True, check=True)
assert result.stdout == "confirmed-value\n", result.stdout
print("Empty Enter, query recovery and valid confirmation passed")

os.makedirs("benchmarks/visual", exist_ok=True)
for scale in ("1", "1.5", "2"):
    subprocess.run(["zig-out/bin/large-list-bench", "check-layout", scale],
        env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, check=True)
print("Viewport, paging and layout frames generated at 100%, 150%, 200%")

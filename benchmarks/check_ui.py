import os
import subprocess

result = subprocess.run(["zig-out/bin/large-list-bench", "check-confirm"],
    env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, capture_output=True, text=True, check=True)
assert result.stdout == "confirmed-value\n", result.stdout
print("Empty Enter, query recovery and valid confirmation passed")

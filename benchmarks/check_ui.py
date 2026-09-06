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

subprocess.run(["zig-out/bin/large-list-bench", "check-incremental"],
    env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, check=True, timeout=10)
with subprocess.Popen(["zig-out/bin/large-list-bench", "check-stream"],
    env={**os.environ, "SDL_VIDEODRIVER": "offscreen"}, stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
    process.stdin.write(b"alpha|wrong-value\nbeta|confirmed-stream\n")
    process.stdin.flush()
    # Keep stdin open while waiting for a selection. A regression times out.
    try:
        process.wait(timeout=10)
        assert process.returncode == 0, process.stderr.read().decode()
        assert process.stdout.read() == b"confirmed-stream\n"
    finally:
        if process.poll() is None:
            process.kill()
print("Partial results, duplicate identity, edit/navigation barriers, pending Enter and immediate Escape passed")

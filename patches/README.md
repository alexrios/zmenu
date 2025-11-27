# zmenu patches

Community patches for zmenu. Each patch adds an optional feature that can be enabled via `config.zig`.

## Available Patches

### history.patch
Track and boost recently selected items in filter results.

**Enable:** Set `history = true` in your `config.zig`

**What it does:**
- Stores history in `~/.local/share/zmenu/history` (or `$XDG_DATA_HOME/zmenu/history`)
- Boosts recently used items to appear first in filtered results
- Configurable max entries via `history_max_entries` (default: 100)

## Applying Patches

```bash
# From zmenu root directory
git apply patches/history.patch

# Or if you want to create a commit
git am patches/history.patch
```

## Creating New Patches

1. Create your feature in `src/features/myfeature.zig`
2. Add config flag to `config.def.zig` (default: false)
3. Register in `src/features.zig` `buildFeatureList()`
4. Generate patch: `git format-patch -1 -o patches/`

See `history.patch` as a reference implementation.

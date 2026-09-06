# zmenu

A cross-platform dmenu-like application launcher built with Zig and SDL3.

## Usage

zmenu reads items from stdin and displays them in a menu:

```bash
# Simple example
echo -e "Apple\nBanana\nCherry\nDate\nEldberry" | zmenu

# From a file
cat items.txt | zmenu

# Use with find
find . -type f | zmenu
```

The selected item is written to stdout, making it easy to use in scripts:

```bash
selected=$(find ~/projects -maxdepth 1 -type d | zmenu)
cd "$selected"
```

### Monitor/Display Selection

To launch zmenu on a specific monitor, use the `--monitor` flag:

```bash
# Primary monitor (default)
echo -e "Item1\nItem2" | zmenu

# Second monitor
echo -e "Item1\nItem2" | zmenu --monitor 1

# Third monitor
echo -e "Item1\nItem2" | zmenu --monitor 2

# Short flag
seq 1 100 | zmenu -m 1
```

Monitor indices are 0-based where 0 is the primary display. If the specified monitor is not available, zmenu will exit with an error message showing the number of available displays.

### Feature-Specific Flags

When features are enabled, they may provide additional command-line flags for runtime configuration. Use `--help` to see available flags:

```bash
zmenu --help
```

**History Feature** (when enabled):
```bash
# Use custom history file
echo -e "Item1\nItem2\nItem3" | zmenu --hist-file /tmp/my_history

# Override history limit
seq 1 1000 | zmenu --hist-limit 50

# Combine flags
echo -e "Item1\nItem2" | zmenu -H /tmp/history --hist-limit 100
```

The history feature tracks your selections and reorders items based on recency, with most recently selected items appearing first.
`--hist-limit` accepts values from 1 through 10000; its default is the compile-time `features.history_max_entries` setting.

The CLI rejects unknown options, positional arguments, duplicate options, and missing values before SDL is initialized. Informational options (`--help`, `--version`, and `--features`) cannot be combined with execution options.

### Responsiveness

zmenu reads stdin **non-blocking** - the window appears immediately and shows a loading indicator while items are being read:

- **Instant feedback** - Window appears right away, even for slow stdin sources.
- **Real-time progress** - Shows "Loaded N items" counter as items arrive.
- **Early cancellation** - Press `Escape` or `Ctrl+C` to exit anytime, even during loading.
- **Batch display** - Items appear all at once after stdin completes (prevents UI jumpiness).

This is especially useful for slow commands:
```bash
# Window appears instantly, shows loading progress
find /large/directory -type f | zmenu

# Can cancel immediately if it takes too long
(echo "Item1"; sleep 10; echo "Item2") | zmenu  # Press Escape to exit early
```

### Keyboard Controls

**Navigation:**
- `↑` / `k` - Move selection up
- `↓` / `j` - Move selection down
- `Tab` - Move to next item
- `Shift+Tab` - Move to previous item
- `Page Up` - Jump up one page
- `Page Down` - Jump down one page
- `Home` - Jump to first item
- `End` - Jump to last item

**Input:**
- Type any text - Fuzzy filter items (case-insensitive, UTF-8 safe)
- `Backspace` - Delete last character (UTF-8 aware)
- `Ctrl+U` - Clear entire input
- `Ctrl+W` - Delete last word

**Actions:**
- `Enter` - Select current item and output to stdout
- `Escape` / `Ctrl+C` - Cancel without selection (works anytime, even during loading)

### Clipboard Support

When enabled via `config.zig` (`clipboard = true`), zmenu automatically copies your selection to the system clipboard when you press Enter. The selection is sent to **both** stdout (normal behavior) and clipboard.

The clipboard feature gracefully handles cases where clipboard access fails, printing a warning but still outputting to stdout.
Exit hooks such as the Linux clipboard event pump run synchronously on the main thread. They share the cooperative `exit_budget_ms` deadline; hooks must check the supplied context because they cannot be interrupted forcibly without risking SDL state.

## Themes

zmenu's theme is configured at compile-time via `config.zig`. Colors are set individually, using one of the built-in theme presets:

```bash
# Copy the default config
cp config.def.zig config.zig

# Edit the colors section in config.zig to use a different theme, e.g.:
#   pub const background: sdl.pixels.Color = theme.dracula.background;
#   pub const foreground: sdl.pixels.Color = theme.dracula.foreground;
#   ... (all 5 color fields)
#
# Or replace all colors at once by changing the theme import:
#   pub const background: sdl.pixels.Color = theme.nord.background;

# Rebuild
zig build
```

### Available Themes

**Catppuccin Family** (pastel themes):
- **latte** (default) - Light pastel with lavender background.
- **mocha** - Dark pastel with purple-gray background.
- **frappe** - Medium-dark pastel.
- **macchiato** - Dark-medium pastel.

**Classic Themes**:
- **dracula** - Popular dark theme with vibrant pink/cyan accents.
- **gruvbox** - Retro warm dark theme with earthy tones.
- **nord** - Cool arctic-inspired theme with blue accents.
- **solarized** - Low-contrast dark theme.

Theme names are case-insensitive (`NORD`, `nord`, and `NoRd` all work).

## Development

- [mise](https://mise.jdx.dev/) for version management.
- **No SDL3 system libraries required!** - `zig-sdl3` bundles everything.

### Setup

1. Install mise (if not already installed):
```bash
curl https://mise.run | sh
```

2. Install Zig via mise (if you don't have it yet):
```bash
mise install
```

3. Build the project:
```bash
mise run build
```

### Available mise Tasks

- `mise run build` - Build the project.
- `mise run run` - Run the application.
- `mise run test` - Run tests.
- `mise run clean` - Clean build artifacts.
- `mise run check` - Check code without building.

### Project Structure

```
zmenu/
├── .mise.toml          # Mise configuration and tasks
├── build.zig           # Build configuration
├── build.zig.zon       # Dependencies (zig-sdl3)
├── config.def.zig      # Default configuration (copy to config.zig to customize)
├── src/
│   ├── main.zig        # Entry point and CLI
│   ├── app.zig         # Core application logic
│   ├── state.zig       # State management (tagged unions)
│   ├── rendering.zig   # Rendering types and color schemes
│   ├── input.zig       # Input handling and UTF-8 utilities
│   ├── sdl_context.zig # SDL initialization and management
│   ├── theme.zig       # Theme definitions (8 color schemes)
│   ├── features.zig    # Compile-time feature hook system
│   └── features/       # Pluggable features
│       ├── history.zig    # History tracking (optional)
│       └── clipboard.zig  # Clipboard integration (optional)
└── docs/               # Documentation
```

## Opinionated Fuzzy Matching Algorithm

The fuzzy matcher allows characters to appear in order but not necessarily consecutively:

```
Query: "abc"
Matches: "AaBbCc", "a_long_b_string_c", "AbsolutelyBigCat"
No Match: "cba", "acb"
```

**Important**: Case-insensitive matching only works for ASCII characters (a-z, A-Z). UTF-8 characters like é, ü, 日 are matched byte-for-byte:
- ✅ "Café" matches "caf" (ASCII part is case-insensitive)
- ❌ "café" does NOT match "cafe" (é ≠ e)
- ✅ "日本語" matches "日本" (exact UTF-8 bytes)

This design choice ensures UTF-8 safety without complex Unicode normalization.

## Design Philosophy

zmenu embraces pragmatic software engineering.

**Architecture:**
- **Modular structure** - Clean separation into focused modules (app, state, rendering, input, features).
- **Type-safe state management** - Tagged unions for compile-time guarantees (no invalid states).
- **Compile-time features** - Zig's answer to dmenu patches: zero-cost abstractions via comptime.
- **Hook-based extensibility** - Features integrate through well-defined lifecycle hooks.

**Performance:**
- **Event-driven rendering** - Only renders when needed, sleeps when idle.
- **Texture caching** - Reuses rendered text to minimize GPU uploads.
- **Smart allocation** - Buffers allocated once, reused every frame.
- **Zero overhead** - Disabled features completely removed from binary.

**Philosophy:**
Like dmenu's patch system, but better: features are enabled at compile-time via `config.zig`, type-checked by the compiler, and auto-update when APIs change. No merge conflicts, no runtime cost, pure Zig.

## Testing

```bash
mise run test
```

## Cross-Platform

**Supported Platforms**: Linux, macOS, Windows.

## Contributing

Discussions, issues and PRs are welcome.

To add a new feature, see [docs/features.md](docs/features.md) for the compile-time feature system and hook API.

## License

AGPL-3.0. See [LICENSE](LICENSE) for details.

Enter confirms only a valid selection. With no matches, the menu stays open so
that the query can be edited. Escape and Ctrl+C still cancel.

The window keeps `window.initial_width` and `window.initial_height` during loading
and search, clamped to the monitor's usable area. Rows and Page Up/Down use the
available height, reserving a footer for counts and position. Text fits the
available pixel width: queries show the tail, and long paths retain their final
filename with a middle ellipsis. UTF-8 boundaries are preserved. Font size and
all layout options remain compile-time configuration.

Stdin uses a cancelable reader with a shared queue capped at 4 MiB of line
content or 4,096 lines, whichever fills first. The consumer holds at most one
additional bounded batch. Partial lines retain only the prefix needed for the
existing UTF-8 truncation rule. Ingestion yields between items after a 4 ms
slice. Queue limits do **not** bound the final item collection, which still grows
with the number of input items. Lines transfer ownership into items without a
second text copy; whitespace trimming, `display|value` and final lines without a
newline retain their behavior.

Typing, navigation and Enter work while stdin is still loading. The footer marks
reading or a pending search; Enter waits for the current query, then confirms a
valid partial result and cancels further reading. This can cause SIGPIPE in the
producer. Escape cancels immediately. Search scans yield every 4 ms between
items; extending fuzzy/prefix queries reuses candidates, while deleting,
replacing or using exact matching scans the collection again. Selection follows
item identity, including items with duplicate values. Consecutive edits are
coalesced before scanning; navigation and confirmation are ordering barriers.

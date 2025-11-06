# zmenu

A cross-platform dmenu-like application launcher built with Zig and SDL3.

## Features

- **Fast and lightweight** menu selection interface
- **Fuzzy matching** - Type letters and they can match anywhere (e.g., "abc" matches "a_b_c")
- **Case-insensitive filtering** - Search without worrying about caps (ASCII only)
- **UTF-8 safe** - Handles multi-byte characters correctly in input and items
- **Multi-line display** - See up to 10 items at once with scrolling
- **Keyboard-driven navigation** with vim-style keybindings
- **Cross-platform** - Runs on Linux, Windows, and macOS without code changes
- **Zero configuration** - Works out of the box with sensible defaults

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

### Keyboard Controls

**Navigation:**
- `↑` / `k` - Move selection up
- `↓` / `j` - Move selection down
- `Tab` - Move to next item
- `Shift+Tab` - Move to previous item
- `Page Up` - Jump up one page (10 items)
- `Page Down` - Jump down one page (10 items)
- `Home` - Jump to first item
- `End` - Jump to last item

**Input:**
- Type any text - Fuzzy filter items (case-insensitive, UTF-8 safe)
- `Backspace` - Delete last character (UTF-8 aware)
- `Ctrl+U` - Clear entire input
- `Ctrl+W` - Delete last word

**Actions:**
- `Enter` - Select current item and output to stdout
- `Escape` / `Ctrl+C` - Cancel without selection

### Display

- Top left: Input prompt with your query
- Top right: Filtered count / Total items
- Bottom right (if needed): Scroll indicator showing visible range
- Selected item has `>` prefix and highlighted color

## Themes

zmenu supports multiple color themes via the `ZMENU_THEME` environment variable:

```bash
# Use a specific theme (note: env var must be set for zmenu, not the input command)
echo -e "Apple\nBanana\nCherry" | ZMENU_THEME=dracula zmenu

# Works with any command
find . -type f | ZMENU_THEME=nord zmenu

# Or export first, then use normally
export ZMENU_THEME=gruvbox
seq 1 100 | zmenu

# Set as default in your shell config (~/.bashrc, ~/.zshrc, etc.)
export ZMENU_THEME=gruvbox
```

### Available Themes

**Catppuccin Family** (pastel themes):
- **mocha** (default) - Dark pastel with purple-gray background
- **latte** - Light pastel with lavender background
- **frappe** - Medium-dark pastel
- **macchiato** - Dark-medium pastel

**Classic Themes**:
- **dracula** - Popular dark theme with vibrant pink/cyan accents
- **gruvbox** - Retro warm dark theme with earthy tones
- **nord** - Cool arctic-inspired theme with blue accents
- **solarized** - Low-contrast dark theme

If `ZMENU_THEME` is not set or contains an invalid name, zmenu defaults to **mocha**.

Theme names are case-insensitive (`NORD`, `nord`, and `NoRd` all work).

## Development

- [mise](https://mise.jdx.dev/) for version management
- **No SDL3 system libraries required!** - zig-sdl3 bundles everything

### Setup

1. Install mise (if not already installed):
```bash
curl https://mise.run | sh
```

2. Install Zig via mise:
```bash
mise install
```

3. Build the project:
```bash
mise run build
```

### Available mise Tasks

- `mise run build` - Build the project
- `mise run run` - Run the application
- `mise run test` - Run tests
- `mise run clean` - Clean build artifacts
- `mise run check` - Check code without building

### Project Structure

```
zmenu/
├── .mise.toml          # Mise configuration and tasks
├── build.zig           # Build configuration
├── build.zig.zon       # Dependencies (zig-sdl3)
├── src/
│   ├── main.zig        # Main application (~740 lines)
│   └── theme.zig       # Theme definitions (8 color themes)
└── README.md
```

## Implementation Details

### Fuzzy Matching Algorithm

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

This project follows a pragmatic approach:

- **Simple, maintainable code** - Single ~500-line file, easy to understand
- **Minimal dependencies** - Just zig-sdl3 (which bundles SDL3)
- **Clear separation of concerns** - Init, event handling, rendering, filtering
- **Performance-conscious but readable** - Optimized where it matters, clear elsewhere
- **Helper methods** - Navigation, text editing extracted to focused functions

## Testing

The project includes automated tests covering critical functionality:

```bash
mise run test  # Run all tests
```

**Test Coverage:**
- Fuzzy matching (basic, case-insensitive, UTF-8 handling)
- UTF-8 boundary detection for safe truncation
- UTF-8 aware character deletion (backspace, word deletion)
- Color comparison
- Configuration validation

All tests use Zig's built-in testing framework and run on every build.

## Cross-Platform

**Supported Platforms**: Linux, macOS, Windows

**Building for different platforms:**

```bash
# Native build
mise run build

# Cross-compile to Windows
zig build -Dtarget=x86_64-windows

# Cross-compile to macOS
zig build -Dtarget=x86_64-macos

# Cross-compile to Linux
zig build -Dtarget=x86_64-linux
```

## Known limitations

- No configuration file support yet
- No history/frecency tracking
- Window size is fixed (800x300)

## Future Enhancements

**Planned:**
- [ ] Configuration file support (`~/.config/zmenu/config.toml`)
- [ ] History tracking with frecency scoring
- [ ] Multi-column layout option
- [ ] Preview pane for file paths
- [ ] Custom keybinding support

**Maybe:**
- [ ] Plugin system for custom filters
- [ ] Custom theme support (user-defined colors)
- [ ] Desktop file integration (.desktop files)
- [ ] Icon support

## Contributing

This is a learning project exploring Zig + SDL3.

Discussions, issues and PRs are welcomed!

## License

This project is open source. Use it however you'd like.

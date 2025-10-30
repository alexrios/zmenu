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
│   └── main.zig        # Main application (726 lines: 534 code + 192 tests)
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

**Platform-specific notes:**
- **Windows**: Works with cmd.exe, PowerShell, and Windows Terminal
- **macOS**: Window positioning on multi-monitor setups may vary
- **Linux**: Tested on X11 and Wayland (via SDL3)

## Changelog

### v0.4 (Current)
- ✅ **Automated testing**: 14 comprehensive tests covering critical paths
- ✅ **Cross-platform verification**: Confirmed Linux/Mac/Windows compatibility
- ✅ **UTF-8 word deletion**: Ctrl+W now properly handles multi-byte characters
- ✅ **UTF-8 safe truncation**: Items and input truncated at character boundaries
- ✅ **Separate scroll buffer**: Eliminated buffer reuse race condition
- ✅ **Input ellipsis margin**: Configurable threshold (100 bytes) for long input indicator
- ✅ **Documentation**: Comprehensive development gotchas and lessons learned

### v0.3
- ✅ **UTF-8 support**: Backspace properly removes multi-byte characters
- ✅ **Page navigation**: Page Up/Page Down for fast scrolling
- ✅ **Ctrl+C support**: Additional quit shortcut
- ✅ **Event-driven rendering**: waitTimeout reduces CPU usage when idle
- ✅ **Reusable buffers**: Render buffers allocated once, reused every frame
- ✅ **Input size limit**: 1KB max input, 4KB max item length
- ✅ **Improved truncation feedback**: Shows ellipsis for long input
- ✅ **Helper methods**: navigateToFirst/Last, navigatePage, deleteLastCodepoint
- ✅ **Config consolidation**: All magic numbers moved to Config struct
- ✅ **Fixed buffer overflow**: Item buffer now sized correctly for 4KB items
- ✅ **Fixed memory leak**: Proper cleanup on NoItemsProvided error

### v0.2
- ✅ Added fuzzy matching with case-insensitive search
- ✅ Multi-line item display (up to 10 visible items)
- ✅ Scroll support with visual indicators
- ✅ Enhanced keyboard controls (Home, End, Ctrl+U, Ctrl+W)
- ✅ Dirty-flag rendering (efficient CPU usage)
- ✅ Fixed memory leaks with proper errdefer cleanup
- ✅ Fixed race conditions in rendering
- ✅ Window centered at top of screen
- ✅ Improved error messages and debugging
- ✅ Larger buffer sizes for items
- ✅ Whitespace trimming for cleaner input

### v0.1 (Initial)
- Basic dmenu functionality
- Simple substring matching
- Single-item display
- SDL3 integration

## Known limitations

- Uses SDL debug text rendering (bitmap font) instead of TTF
- No configuration file support yet
- Colors are hardcoded
- No history/frecency tracking
- Window size is fixed (800x300)

## Future Enhancements

**Planned:**
- [ ] SDL_ttf integration for better text rendering
- [ ] Configuration file support (`~/.config/zmenu/config.toml`)
- [ ] Customizable colors and fonts
- [ ] History tracking with frecency scoring
- [ ] Multi-column layout option
- [ ] Preview pane for file paths
- [ ] Custom keybinding support

**Maybe:**
- [ ] Plugin system for custom filters
- [ ] Theme support
- [ ] Desktop file integration (.desktop files)
- [ ] Icon support

## Contributing

This is a learning project exploring Zig + SDL3.

Discussions, issues and PRs are welcomed!

## License

This project is open source. Use it however you'd like.

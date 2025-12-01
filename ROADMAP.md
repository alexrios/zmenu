# zmenu Roadmap

Aspirational roadmap for zmenu development. Following the suckless philosophy, features are implemented as optional compile-time patches with zero overhead when disabled.

## Philosophy

- **Simplicity first** - Core stays minimal, features are opt-in patches
- **Zero-cost abstractions** - Disabled features add no binary size or runtime cost
- **Compile-time configuration** - No runtime config files, no parsing overhead
- **Cross-platform** - Single codebase for Linux, macOS, Windows

---

## Completed

### v0.1 - Foundation
- [x] Basic dmenu-like functionality
- [x] Fuzzy matching with UTF-8 support
- [x] SDL3 cross-platform rendering
- [x] Theme support (8 built-in color schemes)
- [x] High DPI support

### v0.2 - Modular Architecture
- [x] `config.def.zig` / `config.zig` pattern
- [x] Modular codebase (app, input, types, sdl_context, features)
- [x] Compile-time feature hook system
- [x] History feature (reference patch implementation)
- [x] Patch distribution system

---

## Short Term

### Input & Selection
- [ ] **Multi-select** - Select multiple items with Tab, output all on confirm
- [ ] **Prefix/exact match modes** - Toggle via config (fuzzy is default)
- [ ] **Case sensitivity toggle** - Already in config, needs UI indicator
- [ ] **Vim keybindings** - j/k navigation, optional patch

### Visual
- [ ] **Horizontal mode** - Single-line dmenu style layout
- [ ] **Custom prompt** - Configurable prompt text (default: ">")
- [ ] **Item icons** - Optional icon prefix support (Nerd Fonts)
- [ ] **Scroll indicators** - Visual feedback for long lists

### Performance
- [ ] **Lazy rendering** - Only render visible items
- [ ] **Async input** - Non-blocking stdin for large inputs
- [ ] **Result caching** - Cache filter results between keystrokes
- [ ] **Daemon mode** - Server-client architecture for < 10ms repeated launches (120ms → 10ms)

---

## Medium Term

### Integration Features
- [ ] **Password mode** - Hide input characters (for dmenu_pass scripts)
- [ ] **Desktop entry parser** - Parse .desktop files for app launcher
- [ ] **App launcher examples** - Platform-specific launcher scripts (Linux/Mac/Windows)
- [ ] **Custom scripts directory** - ~/.config/zmenu/scripts/ auto-discovery
- [ ] **JSON output mode** - Structured output for scripting

### Platform Polish
- [ ] **Wayland-native** - Direct Wayland support (currently via XWayland)
- [ ] **Windows installer** - MSI/portable distribution
- [ ] **macOS app bundle** - Proper .app with code signing

### Advanced Matching
- [ ] **Scoring algorithm** - Rank matches by quality (not just order)
- [ ] **Field splitting** - Match against specific fields (tab-separated)
- [ ] **Regex mode** - Full regex pattern matching

---

## Long Term

### Extensibility
- [ ] **Lua scripting** - Optional Lua hooks for complex logic
- [ ] **Plugin system** - Dynamic loading for non-compile-time features
- [ ] **IPC interface** - Control zmenu from external scripts

### Ecosystem
- [ ] **zmenu-launcher** - Reference app launcher implementations
  - Linux: .desktop file parser + gtk-launch integration
  - macOS: .app bundle detection + `open -a` launcher
  - Windows: Start Menu .lnk parser + PowerShell integration
- [ ] **zmenu-scripts** - Curated script collection (wifi, bluetooth, power menu)
- [ ] **Theme gallery** - Community theme contributions
- [ ] **Integration guides** - Docs for i3, sway, Hyprland, etc.

### Experimental
- [ ] **AI-powered matching** - Local embedding-based semantic search
- [ ] **Voice input** - Speech-to-text for accessibility
- [ ] **Touch support** - Mobile-friendly gestures

---

## Non-Goals

These are explicitly out of scope to maintain simplicity:

- **Runtime configuration files** - Use compile-time config only
- **Built-in networking** - No HTTP, no auto-updates
- **Database backend** - History is a flat file, not SQLite
- **GUI configuration** - Edit config.zig, rebuild
- **Backwards compatibility shims** - Clean breaks over cruft

---

## Contributing

Want to implement something from this roadmap?

1. Check if there's an existing patch in `patches/`
2. Follow the feature implementation pattern in `src/features/history.zig`
3. Keep the feature disabled by default in `config.def.zig`
4. Submit your patch for community sharing

See `patches/README.md` for patch creation guidelines.

---

## Version Strategy

- **0.x** - Active development, API may change
- **1.0** - Stable core, patch ecosystem established
- **Post-1.0** - Core frozen, features via patches only

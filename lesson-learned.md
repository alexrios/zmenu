## Development Gotchas & Lessons Learned

### UTF-8 Handling

**Problem**: Zig's `ArrayList(u8).pop()` removes a single byte, which corrupts multi-byte UTF-8 characters.

**Solution**: Implement `deleteLastCodepoint()` that detects UTF-8 continuation bytes (0x80-0xBF pattern) and removes entire codepoints:

```zig
fn deleteLastCodepoint(self: *App) void {
    if (self.input_buffer.items.len == 0) return;
    var i = self.input_buffer.items.len - 1;
    // Walk backwards to find start of codepoint
    while (i > 0 and (self.input_buffer.items[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    self.input_buffer.shrinkRetainingCapacity(i);
}
```

**Impact**: Used for backspace and word deletion (Ctrl+W).

---

### Buffer Size Alignment

**Problem**: Item buffer was 1024 bytes but max item length was 4096 bytes, causing truncation errors.

**Solution**: Buffer sizes must account for max content + prefix + null terminator:

```zig
prompt_buffer_size: usize = 1024 + 16,  // max_input_length + prefix + safety
item_buffer_size: usize = 4096 + 16,    // max_item_length + prefix + safety
```

**Lesson**: Document dependencies between config values in comments.

---

### UTF-8 Truncation

**Problem**: Slicing at arbitrary byte positions (`text[0..max_len]`) can split multi-byte UTF-8 characters, creating invalid UTF-8.

**Solution**: Implement `findUtf8Boundary()` that walks backwards to find the last valid character boundary:

```zig
fn findUtf8Boundary(text: []const u8, max_len: usize) usize {
    if (text.len <= max_len) return text.len;
    var pos = max_len;
    while (pos > 0 and (text[pos] & 0xC0) == 0x80) {
        pos -= 1;
    }
    return pos;
}
```

**Applied to**: Loading items from stdin, displaying long input with ellipsis.

---

### Buffer Reuse Race Condition

**Problem**: Using the same buffer (`count_buffer`) for both count display and scroll indicator in one render pass. The second use overwrites the first.

**Solution**: Allocate separate `scroll_buffer`. Even though it worked by accident (count rendered before scroll), this prevents future bugs.

**Lesson**: Each piece of displayed text needs its own buffer if they coexist in a single frame.

---

### Zig 0.15.2 API Changes

**Major changes from earlier Zig versions:**

1. **Build system**:
   ```zig
   // Old: root_source_file
   // New: root_module with createModule()
   exe.root_module = b.createModule(.{
       .root_source_file = b.path("src/main.zig"),
   });
   ```

2. **ArrayList requires allocator parameter**:
   ```zig
   // All methods need allocator
   try list.append(allocator, item);
   list.deinit(allocator);
   ```

3. **SDL3 wrapper**:
    - Renderer is `sdl.render.Renderer` not `sdl.video.Renderer`
    - Methods: `setDrawColor()` not `setColor()`
    - Timer: `delayMilliseconds()` not `delay()`

**Lesson**: When using bleeding-edge Zig, API docs may be outdated. Use `grep` on stdlib source as reference.

---

### Cross-Platform I/O

**Initially thought**: `std.posix.STDIN_FILENO` is POSIX-specific and won't work on Windows.

**Reality**: In Zig 0.15.2, `std.posix` is an abstraction layer that maps to Windows APIs on Windows and POSIX on Unix-like systems. `STDIN_FILENO` works cross-platform.

**Lesson**: Trust Zig's standard library abstractions - they're designed to be cross-platform.

---

### Event Loop Performance

**Initial approach**: Constant polling with fixed 16ms delay:
```zig
while (running) {
    while (sdl.events.poll()) |event| { ... }
    sdl.timer.delayMilliseconds(16);  // Burns CPU
}
```

**Optimized**: Event-driven with timeout:
```zig
while (running) {
    const has_event = sdl.events.waitTimeout(16);  // Sleeps when idle
    if (has_event) {
        while (sdl.events.poll()) |event| { ... }
    }
}
```

**Impact**: Reduces CPU usage from ~6% to <1% when idle.

---

### Memory Management

**Critical pattern**: Use `errdefer` for cleanup on initialization failures:

```zig
const window, const renderer = try sdl.render.Renderer.initWithWindow(...);
errdefer renderer.deinit();  // Cleanup if subsequent operations fail
errdefer window.deinit();

const buffer = try allocator.alloc(u8, size);
errdefer allocator.free(buffer);  // Cleanup if subsequent operations fail
```

**Gotcha**: Manual cleanup in error paths (like `NoItemsProvided`) must NOT free resources that errdefer will handle - that causes double-free.

**Solution**: Only manually free resources NOT covered by errdefer:
```zig
if (app.items.items.len == 0) {
    // ArrayLists not covered by errdefer
    app.items.deinit(allocator);
    app.filtered_items.deinit(allocator);
    // Buffers WILL be freed by errdefer - don't free here!
    return error.NoItemsProvided;
}
```

---

### Test Integration

**Problem**: Tests couldn't import `sdl3` module initially.

**Solution**: Tests need the same module imports as the main binary:

```zig
// In build.zig
const unit_tests = b.addTest(.{ ... });
unit_tests.root_module.addImport("sdl3", sdl3.module("sdl3"));
```

**Lesson**: Test target needs explicit module imports even though it compiles the same source file.
# Feature System Documentation

## Philosophy: Comptime as a Patching System

zmenu's feature system is inspired by dmenu's patching philosophy but leverages Zig's compile-time capabilities for type safety and zero overhead.

### Advantages Over Git Patches

- **No merge conflicts** - Features compose without conflicts
- **Auto-updating** - Features update when APIs change
- **Type-safe** - Validated at compile time
- **Zero cost** - Disabled features completely eliminated from binary
- **Compatibility checks** - Invalid combinations caught at compile time

### How It Works

Features are registered at compile time via `config.zig`. When a feature is disabled, the compiler completely eliminates it from the binary — no runtime checks, no unused code, no binary bloat.

## Feature Lifecycle

```
1. COMPILE TIME
   - buildFeatureList() registers enabled features
   - validateCliFlags() checks for duplicate flags
   - Disabled features never imported

2. APP INITIALIZATION (App.init)
   - initStates() creates storage array
   - initAll() calls each feature's onInit hook
   - Features return state pointers

3. RUNTIME
   - afterFilter hook: post-process results (hot path)
   - onSelect hook: handle item selection
   - onExit hook: pre-shutdown cleanup (with timeout)

4. APP CLEANUP (App.deinit)
   - deinitAll() calls each feature's onDeinit hook
   - Features free their state
```

## Adding a New Feature

### Step 1: Create Feature Module

Create `src/features/myfeature.zig`:

```zig
const std = @import("std");
const features_mod = @import("../features.zig");
const types = @import("../types.zig");

// Feature state (optional - return null from onInit if no state needed)
const MyState = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) !*MyState {
        const state = try allocator.create(MyState);
        state.* = .{
            .allocator = allocator,
            .data = std.ArrayList(u8).empty,
        };
        return state;
    }

    fn deinit(self: *MyState) void {
        self.data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState {
    const state = try MyState.init(init_data.allocator);
    return @ptrCast(state);
}

fn onDeinit(state_ptr: ?features_mod.FeatureState, _: std.mem.Allocator) void {
    const state = features_mod.castState(MyState, state_ptr) orelse return;
    state.deinit();
}

fn afterFilter(
    state_ptr: ?features_mod.FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const types.Item,
) void {
    const state = features_mod.castState(MyState, state_ptr) orelse return;
    _ = state;
    _ = filtered_items;
    _ = all_items;
    // Post-process filtered results here
}

fn onSelect(state_ptr: ?features_mod.FeatureState, selected_item: types.Item) void {
    const state = features_mod.castState(MyState, state_ptr) orelse return;
    _ = state;
    _ = selected_item;
    // Handle item selection here
}

pub const feature = features_mod.Feature{
    .name = "myfeature",
    .hooks = .{
        .onInit = &onInit,
        .onDeinit = &onDeinit,
        .afterFilter = &afterFilter,
        .onSelect = &onSelect,
    },
};
```

### Step 2: Add Config Flag

In `config.def.zig`, add to the `features` struct:

```zig
pub const features = struct {
    // ... existing flags ...
    pub const myfeature: bool = false;  // Disabled by default
};
```

### Step 3: Register Feature

In `src/features.zig`, add to `buildFeatureList()`:

```zig
fn buildFeatureList() []const Feature {
    comptime {
        var list: []const Feature = &.{};

        // Existing features...

        if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
            list = list ++ &[_]Feature{@import("features/myfeature.zig").feature};
        }

        validateCliFlags(list);
        return list;
    }
}
```

Add compile-time validation inline if needed:

```zig
if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
    if (@hasDecl(config.features, "myfeature_max_items")) {
        if (config.features.myfeature_max_items == 0)
            @compileError("myfeature_max_items must be > 0");
    }
    list = list ++ &[_]Feature{@import("features/myfeature.zig").feature};
}
```

### Step 4: Users Enable Feature

Users copy `config.def.zig` to `config.zig` and set:

```zig
pub const features = struct {
    pub const myfeature: bool = true;
};
```

Then rebuild: `zig build`

## Available Hooks

All hooks are optional — only implement what you need.

### onInit

**Called:** Once during `App.init()`, after core initialization

**Signature:**
```zig
fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState
```

**Parameters via `FeatureInitData`:**
- `allocator` - Use this for any allocations
- `cli_values` - Parsed CLI flag values for this feature
- `cli_flags` - Flag declarations (for name-based lookup)

**Convenience getters:**
- `init_data.getString("flag-name")` - Returns `?[]const u8`
- `init_data.getInt("flag-name")` - Returns `?i64`
- `init_data.getBool("flag-name")` - Returns `bool` (false if absent)
- `init_data.getFlag("flag-name")` - Returns `?FlagValue` (raw union)

**Returns:**
- `?FeatureState` - Pointer to your state (or `null` if no state needed)
- Error if initialization fails (aborts `App.init()`)

### onDeinit

**Called:** During `App.deinit()` for cleanup

**Signature:**
```zig
fn onDeinit(state: ?features_mod.FeatureState, allocator: std.mem.Allocator) void
```

Must handle `null` state gracefully. No error returns.

### afterFilter

**Called:** After fuzzy matching, before rendering. **This is the hot path** — called on every keystroke that changes filter results.

**Signature:**
```zig
fn afterFilter(
    state: ?features_mod.FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const types.Item,
) void
```

- `filtered_items` is **mutable** — reorder, remove items freely
- `all_items` is **read-only**
- Each `Item` has `.display` (shown in UI) and `.value` (output to stdout)

### onSelect

**Called:** When user confirms selection (presses Enter)

**Signature:**
```zig
fn onSelect(state: ?features_mod.FeatureState, selected_item: types.Item) void
```

The `Item` has both `.display` and `.value` fields — choose which to act on.

### onExit

**Called:** After `onSelect`, before SDL shutdown. Must complete within `config.exit_timeout_ms` (default: 500ms). No allocations, no error returns.

**Signature:**
```zig
fn onExit(state: ?features_mod.FeatureState) void
```

Use for cleanup that requires SDL to still be alive (e.g., clipboard event pumping on Linux).

## CLI Flags

Features can declare their own command-line flags:

```zig
pub const feature = features_mod.Feature{
    .name = "myfeature",
    .hooks = .{ .onInit = &onInit },
    .cli_flags = &[_]features_mod.CliFlag{
        .{
            .long = "my-option",
            .short = 'o',
            .description = "Description for --help",
            .value_type = .string,
        },
        .{
            .long = "my-limit",
            .description = "Maximum entries",
            .value_type = .int,
            .default = features_mod.FlagValue{ .int = 100 },
        },
    },
};
```

**Flag types:** `.string` (requires argument), `.int` (requires integer), `.bool` (no argument)

**Flag properties:** `long` (required), `short` (optional), `description` (required), `value_type` (required), `required` (default: false), `default` (optional)

**Compile-time validation:**
- Duplicate flags across features detected at compile time
- Required flags with default values rejected
- Help text auto-generated from flag metadata

**Access in onInit:**
```zig
fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState {
    const custom_path = init_data.getString("my-option");
    const limit: usize = if (init_data.getInt("my-limit")) |v| @intCast(v) else 100;
    // ...
}
```

## State Casting

Use `features_mod.castState` to convert opaque state pointers to concrete types:

```zig
fn afterFilter(state_ptr: ?features_mod.FeatureState, ...) void {
    const state = features_mod.castState(MyState, state_ptr) orelse return;
    // state is now *MyState
}
```

This centralizes the `@ptrCast/@alignCast` pattern and handles `null` in one call.

## Best Practices

### Memory Management

- Allocate state in `onInit`, free in `onDeinit`
- Use the provided allocator
- Handle `null` state in all hooks via `castState(...) orelse return`
- Do not allocate in `afterFilter` (hot path) — pre-allocate in `onInit`

### Performance

- Keep `afterFilter` fast — users notice lag on every keystroke
- Keep `onSelect` and `onExit` fast — they block shutdown
- Cache expensive computations in state

### Error Handling

- `onInit` can return errors (they propagate and fail `App.init()`)
- All other hooks cannot return errors — log to `std.log.warn` instead
- Degrade gracefully: return `null` from `onInit` if the feature is non-critical

## Architecture Notes

### Zero-Cost Abstraction

When `enabled_count == 0`:
- `FeatureStates` type is `void`
- All hook call functions become no-ops
- Compiler optimizes away all feature code

When features are enabled:
- Hooks called via `inline for` loops (unrolled at compile time)
- Only registered hooks are called (null checks optimized away)
- Feature state indexed by comptime index — dispatch is always correct

## Real-World Examples

- `src/features/history.zig` - Stateful feature with file I/O, afterFilter reordering, CLI flags
- `src/features/clipboard.zig` - Stateless feature using SDL clipboard API, platform-specific onExit

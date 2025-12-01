# Feature System Documentation

## Philosophy: Comptime as a Patching System

zmenu's feature system is inspired by dmenu's patching philosophy but leverages Zig's compile-time capabilities for type safety and zero overhead.

### Advantages Over Git Patches

**Like dmenu's patches, but better:**

- ✓ **No merge conflicts** - Features compose without conflicts
- ✓ **Auto-updating** - Features update when APIs change
- ✓ **Type-safe** - Validated at compile time
- ✓ **Zero cost** - Disabled features completely eliminated from binary
- ✓ **Compatibility checks** - Invalid combinations caught at compile time

### How It Works

Features are registered at compile time via `config.zig`. When a feature is disabled, the compiler completely eliminates it from the binary:

- No runtime checks
- No unused code
- No binary bloat

This is the Zig-native approach to customization.

## Feature Lifecycle

```
┌─────────────────────────────────────────────────────────┐
│ 1. COMPILE TIME                                         │
│    - buildFeatureList() registers enabled features      │
│    - validateFeatures() checks compatibility            │
│    - Disabled features never imported                   │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ 2. APP INITIALIZATION (App.init)                        │
│    - initStates() creates storage array                 │
│    - initAll() calls each feature's onInit hook         │
│    - Features return state pointers                     │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ 3. RUNTIME                                              │
│    - afterFilter hook: post-process results (hot path)  │
│    - onSelect hook: handle item selection               │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ 4. APP CLEANUP (App.deinit)                             │
│    - deinitAll() calls each feature's onDeinit hook     │
│    - Features free their state                          │
└─────────────────────────────────────────────────────────┘
```

## Adding a New Feature (Creating a "Zig Patch")

### Step 1: Create Feature Module

Create `src/features/myfeature.zig`:

```zig
const std = @import("std");
const features = @import("../features.zig");

// Feature state (optional - can be null if no state needed)
const State = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) !*State {
        const state = try allocator.create(State);
        state.* = .{
            .allocator = allocator,
            .data = std.ArrayList(u8).init(allocator),
        };
        return state;
    }

    fn deinit(self: *State) void {
        self.data.deinit();
        self.allocator.destroy(self);
    }
};

// Hook implementations
fn onInit(allocator: std.mem.Allocator) !?features.FeatureState {
    const state = try State.init(allocator);
    return @ptrCast(state);
}

fn onDeinit(state: ?features.FeatureState, allocator: std.mem.Allocator) void {
    _ = allocator;
    if (state) |s| {
        const typed_state: *State = @ptrCast(@alignCast(s));
        typed_state.deinit();
    }
}

fn afterFilter(
    state: ?features.FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const []const u8,
) void {
    _ = state;
    _ = filtered_items;
    _ = all_items;
    // Post-process filtered results here
}

fn onSelect(state: ?features.FeatureState, selected_item: []const u8) void {
    _ = state;
    _ = selected_item;
    // Handle item selection here
}

// Feature registration
pub const feature = features.Feature{
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
    pub const myfeature: bool = false;  // Disabled by default

    // Feature-specific config (optional)
    pub const myfeature_max_items: usize = 100;
};
```

### Step 3: Register Feature

In `src/features.zig`, add to `buildFeatureList()`:

```zig
fn buildFeatureList() []const Feature {
    comptime {
        validateFeatures();
        var list: []const Feature = &.{};

        // Existing features...
        if (@hasDecl(config.features, "history") and config.features.history) {
            list = list ++ &[_]Feature{@import("features/history.zig").feature};
        }

        // Add your feature
        if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
            list = list ++ &[_]Feature{@import("features/myfeature.zig").feature};
        }

        return list;
    }
}
```

### Step 4: Add Validation (Optional)

If your feature has constraints or incompatibilities, add validation in `validateFeatures()`:

```zig
fn validateFeatures() void {
    comptime {
        // Check incompatible features
        if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
            if (@hasDecl(config.features, "conflicting_feature") and config.features.conflicting_feature) {
                @compileError("Cannot enable both myfeature and conflicting_feature");
            }
        }

        // Validate feature-specific settings
        if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
            if (@hasDecl(config.features, "myfeature_max_items")) {
                if (config.features.myfeature_max_items == 0) {
                    @compileError("myfeature_max_items must be > 0");
                }
            }
        }
    }
}
```

### Step 5: Users Enable Feature

Users copy `config.def.zig` to `config.zig` and set:

```zig
pub const features = struct {
    pub const myfeature: bool = true;  // Enable it
};
```

Then rebuild: `mise run build`

## Available Hooks

All hooks are **optional** - only implement what you need.

### onInit

**Called:** Once during `App.init()`, after core initialization

**Purpose:** Allocate and initialize feature-specific state

**Signature:**
```zig
fn onInit(allocator: std.mem.Allocator) anyerror!?FeatureState
```

**Parameters:**
- `allocator` - Use this for any allocations

**Returns:**
- `?FeatureState` - Pointer to your state (or `null` if no state needed)
- Error if initialization fails (aborts `App.init()`)

**Example use cases:**
- Load history from disk
- Allocate caches
- Read configuration files
- Initialize data structures

**Important:**
- Errors propagate up and fail `App.init()`
- Cleanup happens via `errdefer` in `App.init()`

### onDeinit

**Called:** During `App.deinit()` for cleanup

**Purpose:** Free feature state and owned resources

**Signature:**
```zig
fn onDeinit(state: ?FeatureState, allocator: std.mem.Allocator) void
```

**Parameters:**
- `state` - The state returned from `onInit` (may be `null`)
- `allocator` - Same allocator passed to `onInit`

**Important:**
- Called even if other hooks never ran
- Must handle `null` state gracefully
- No error returns - must not fail

**Example use cases:**
- Flush history to disk
- Free caches
- Close file handles
- Cleanup data structures

### afterFilter

**Called:** After fuzzy matching, before rendering

**Purpose:** Post-process filtered results (reorder, re-score, filter further)

**Signature:**
```zig
fn afterFilter(
    state: ?FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const []const u8,
) void
```

**Parameters:**
- `state` - Feature state from `onInit`
- `filtered_items` - **Mutable** ArrayList of indices into `all_items`
- `all_items` - **Read-only** array of all input items

**Important:**
- ⚠️ **HOT PATH** - Called on every keystroke
- Keep this FAST - users notice lag here
- Can freely modify `filtered_items` (reorder, remove items)
- Cannot modify `all_items`

**Example use cases:**
- Reorder by history frequency
- Boost recently selected items
- Apply custom scoring
- Filter by additional criteria

**Example:**
```zig
fn afterFilter(
    state: ?FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const []const u8,
) void {
    if (state) |s| {
        const history: *History = @ptrCast(@alignCast(s));

        // Stable sort by frequency (preserves fuzzy match order for ties)
        std.mem.sort(usize, filtered_items.items, history, struct {
            fn lessThan(h: *History, a: usize, b: usize) bool {
                const freq_a = h.getFrequency(all_items[a]);
                const freq_b = h.getFrequency(all_items[b]);
                return freq_a > freq_b;  // Higher frequency first
            }
        }.lessThan);
    }
}
```

### onSelect

**Called:** When user confirms selection (presses Enter)

**Purpose:** React to item selection

**Signature:**
```zig
fn onSelect(state: ?FeatureState, selected_item: []const u8) void
```

**Parameters:**
- `state` - Feature state from `onInit`
- `selected_item` - The text of the selected item

**Important:**
- Called just before app exits
- Keep this FAST - user is waiting
- No error returns - must not fail

**Example use cases:**
- Record to history file
- Update access timestamps
- Send IPC notifications
- Log selection

## Advanced: Config Transforms

Most features don't need this. Only use config transforms when your feature genuinely needs to modify app-wide settings at compile time.

### When to Use

- Feature needs larger buffer sizes
- Feature changes default window dimensions
- Feature replaces core algorithms

### How It Works

1. Features export a `configTransform` function
2. Function takes base config type, returns modified config type
3. Transforms applied in registration order
4. Later transforms see changes from earlier transforms

### Example

In your feature module:

```zig
pub fn configTransform(comptime base_cfg: type) type {
    return struct {
        pub usingnamespace base_cfg;  // Inherit everything

        // Override specific nested values
        pub const limits = struct {
            pub usingnamespace base_cfg.limits;  // Keep other limits
            pub const max_visible_items: usize = 50;  // Feature needs more
        };
    };
}
```

Register in `features.zig` `applyConfigTransforms()`:

```zig
pub fn applyConfigTransforms(comptime base_config: type) type {
    comptime {
        var result = base_config;

        // Existing transforms...
        if (@hasDecl(config.features, "history") and config.features.history) {
            const history_mod = @import("features/history.zig");
            if (@hasDecl(history_mod, "configTransform")) {
                result = history_mod.configTransform(result);
            }
        }

        // Add your transform
        if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
            const myfeature_mod = @import("features/myfeature.zig");
            if (@hasDecl(myfeature_mod, "configTransform")) {
                result = myfeature_mod.configTransform(result);
            }
        }

        return result;
    }
}
```

### Pattern for Transforms

- Always `usingnamespace` to inherit unchanged values
- Only override what you need to change
- Document why the transform is necessary
- Test with and without the feature enabled

## Best Practices

### Memory Management

**Do:**
- Allocate state in `onInit`, free in `onDeinit`
- Use the provided allocator
- Handle `null` state in all hooks

**Don't:**
- Allocate in hot path hooks (`afterFilter`)
- Leak memory
- Assume state is non-null

### Performance

**Do:**
- Keep `afterFilter` fast (hot path)
- Keep `onSelect` fast (blocks exit)
- Cache expensive computations in state
- Use stable sorts to preserve fuzzy match order

**Don't:**
- Do I/O in `afterFilter` (file reads, network)
- Do expensive computation on every keystroke
- Block the event loop

### Error Handling

**Do:**
- Return errors from `onInit` (they propagate)
- Handle all errors in other hooks
- Log errors to stderr if needed

**Don't:**
- Return errors from `onDeinit`, `afterFilter`, or `onSelect` (not allowed)
- Panic or crash
- Silently ignore important errors

### Testing

**Do:**
- Test with feature enabled and disabled
- Test with empty state
- Test error paths in `onInit`
- Test compatibility with other features

**Don't:**
- Assume other features are enabled
- Rely on execution order of features
- Modify shared global state

## Debugging

### Check What's Compiled In

Add to `main.zig`:

```zig
const features = @import("features.zig");
_ = features.printFeatureReport();
```

Output appears in compile diagnostics:

```
zmenu features:
  ✓ history
  ✓ myfeature

Configuration:
  - max_visible_items: 20
  - case_sensitive: false
  - match_mode: fuzzy
```

### Common Issues

**"Feature not working"**
- Check if it's compiled in (see above)
- Check if config flag is set to `true`
- Check if using `config.zig` (not `config.def.zig`)

**"Compile error: feature not found"**
- Feature not registered in `buildFeatureList()`
- Typo in feature name or path

**"Conflict with another feature"**
- Check `validateFeatures()` for incompatibilities
- Disable conflicting feature or use different approach

## Examples

### Simple Feature (No State)

```zig
fn onSelect(_: ?features.FeatureState, selected: []const u8) void {
    std.debug.print("Selected: {s}\n", .{selected});
}

pub const feature = features.Feature{
    .name = "debug_print",
    .hooks = .{ .onSelect = &onSelect },
};
```

### Feature with State

See the full example in "Step 1: Create Feature Module" above.

### Real-World: History Feature

See `src/features/history.zig` for a complete implementation that:
- Loads history from disk in `onInit`
- Reorders results in `afterFilter` based on frequency
- Records selections in `onSelect`
- Flushes to disk in `onDeinit`

## Architecture Notes

### Zero-Cost Abstraction

When `enabled_count == 0`:
- `FeatureStates` type is `void`
- All hook functions become no-ops
- Compiler optimizes away all feature code

When features are enabled:
- Hooks called via `inline for` loops
- Compiler unrolls loops at compile time
- Only registered hooks are called (null checks optimized away)

### Type Safety

- All features validated at compile time
- Invalid configurations caught before runtime
- No dynamic dispatch or runtime type checks

### Extensibility

Adding a new hook type:
1. Add to `Hooks` struct in `features.zig`
2. Add call function (`callNewHook`)
3. Call from appropriate place in `app.zig`
4. Update this documentation

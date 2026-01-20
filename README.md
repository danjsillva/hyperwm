# HyperWM

A minimal, fast window manager for macOS built in Swift. Designed for deterministic hotkey behavior with the Hyper key (Cmd+Alt+Ctrl+Shift).

## Core Principles

### 1. Zero Gambiarras (No Hacks)
- Clean, direct implementations only
- No workarounds that mask underlying issues
- If something doesn't work, fix it properly or remove it
- Code should be readable and maintainable

### 2. Performance Paranoia
- Native Swift + Accessibility API (no AppleScript overhead)
- Minimal memory footprint (~15MB release, ~35MB debug)
- **Zero polling** - fully event-driven (AX Observer + NSWorkspace notifications)
- Direct CGEvent tap for hotkeys (lowest latency possible)
- Pre-position windows before activation (avoid visual flicker)
- Lazy-loaded caches (profile directories, running apps)

### 3. Extremely Customized (Sob Medida)
- Built specifically for one workflow, not general-purpose
- No feature bloat - only what's actually used
- Brave profile support for Personal/Bossa workflow
- Apps configured for actual daily use (Ghostty, Slack, Notes, etc.)
- Two layout modes that match real usage patterns (full + master-stack)

## Features

- **Two layout modes**: Full (stacked maximized) and BSP (master-stack tiling)
- **Per-app toggle**: Show/hide apps with single hotkey
- **Brave profile support**: Separate hotkeys for different browser profiles
- **Multi-display**: Move windows between displays, focus displays
- **Focus border**: Visual indicator for active window (toggleable)
- **Floating windows**: Auto-detect popups, settings, small windows + manual toggle
- **Status bar**: Shows current display + layout mode (e.g., "1F" = Display 1, Full mode)
- **Hot reload**: Config changes apply automatically via FSEvents
- **Menu bar controls**: Gaps, layout, border, launch at login - all from menu

## Requirements

- macOS 10.12+ (uses `hidutil` for key remapping)
- Accessibility permissions

## Installation

```bash
cd ~/.config/hyperwm
swift build
.build/debug/HyperWM &
```

## Hotkeys (Hyper + key)

| Key | Action |
|-----|--------|
| E | Toggle Ghostty |
| R | Toggle Slack |
| A | Toggle Calendar |
| S | Toggle Reminders |
| D | Toggle Notes |
| F | Toggle Finder |
| Q | Toggle Brave (Personal profile) |
| W | Toggle Brave (Bossa profile) |
| T | Toggle float (remove/add window from tiling) |
| Space | Move window to other display |
| Tab | Cycle windows on current display |
| ` | Toggle layout mode (full/bsp) |
| 1 | Focus display 1 |
| 2 | Focus display 2 |

## Menu Bar

Click the status bar icon to access:

```
☑ Show Active Window Border      Toggle focus border visibility
☑ Use Built-In Hyper (Caps Lock) Caps Lock as Hyper key (see below)
○ Launch at Login                Start HyperWM on system boot
────────────
  Layout ▸                       Full / BSP (Master-Stack)
  Gaps ▸                         0 / 5 / 10 / 15 / 20 px
────────────
  Reload Config                  Re-read config.json
  Restart                        Restart the window manager
────────────
  Quit
```

## Built-in Hyper Key (Caps Lock)

When "Use Built-in Hyper (Caps Lock)" is enabled:

- **Hold Caps Lock + key** = Hyper combo (Cmd+Alt+Ctrl+Shift + key)
- **Tap Caps Lock** (quick press <200ms, no combo) = Toggle Caps Lock ON/OFF

### How it works

Uses `hidutil` (native macOS) to remap Caps Lock → F18 at the system level, then CGEventTap intercepts F18 as the Hyper modifier. No kernel extensions, no Input Monitoring permission, no Karabiner needed.

```
Caps Lock → hidutil → F18 → CGEventTap → Hyper modifier
```

## Configuration

Edit `~/.config/hyperwm/config.json` to customize bindings. Changes are applied automatically via FSEvents (no restart needed).

---

# Critical Decisions & Lessons Learned

## Architecture

### 1. CGEvent Tap for Hotkeys
**Decision**: Use CGEvent tap instead of NSEvent global monitor.
**Why**: More reliable, works even when app is not focused, lower latency.
**Gotcha**: Requires Accessibility permissions.

### 2. AXUIElement for Window Management
**Decision**: Direct Accessibility API instead of AppleScript.
**Why**: Much faster, no subprocess overhead, more control.
**Gotcha**: Coordinate system differs from NSScreen (AX uses top-left origin, NSScreen uses bottom-left).

### 3. Event-driven Layout Enforcement
**Decision**: AX Observer for window move/resize events + NSWorkspace notifications.
**Why**: Zero polling overhead, responds only when changes actually occur.
**Implementation**: Uses `kAXMovedNotification` and `kAXResizedNotification` on focused window.

## Coordinate System Conversion

**Critical Bug Fixed**: Windows appearing at wrong positions.

```swift
// NSScreen: origin at bottom-left
// AX API: origin at top-left
let mainScreenHeight = NSScreen.screens[0].frame.height
let axY = mainScreenHeight - visibleFrame.maxY
```

Always convert when going between NSScreen and AX coordinates.

## Window Identification

### Same-App Windows (Brave Profiles)
**Problem**: Multiple Brave windows have same PID and same frame (in full mode).
**Solution**: Identify by window title suffix - Brave format is "Page Title - Profile Name".

```swift
// Use suffix match for accuracy (avoids false positives if page title contains profile name)
if title.hasSuffix(" - \(profile)") || title == profile {
    // This window belongs to this profile
}
```

### isSameWindow Comparison
**Problem**: Comparing by PID + frame fails for stacked windows.
**Solution**: For same-app comparison, use title-based identification.

## Toggle Behavior

### Regular Apps
- If active: `app.hide()` (hides all windows)
- If not active: `app.activate()` (shows all windows)

### Brave Profiles (Multi-window same app)
- If this profile focused: `app.hide()` (hides entire Brave app)
- If other profile focused: `raise` + `activate` target window

**Design Decision**: Only ONE Brave profile visible at a time. Simplifies mental model and avoids window juggling.

## Smooth Window Transitions

### Problem
Window appears at old size, then resizes = visual flicker.

### Solution
1. Set window position/size BEFORE activating
2. Schedule retile via debounced `scheduleRetile()` (100ms debounce)
3. AX Observer catches any subsequent resize events

```swift
// Pre-position at correct size
maximizeWindowOnScreen(window, screen: targetScreen)
// Then activate
app.activate(options: [.activateIgnoringOtherApps])
// Debounced retile (coalesces rapid changes)
scheduleRetile()
```

## Floating Windows

### Detection Criteria
1. **Manual toggle**: Hyper+T to float/unfloat any window
2. **Bundle ID whitelist**: System Settings, Calculator, 1Password, etc.
3. **Window subrole**: Dialogs, sheets, floating windows
4. **Size threshold**: < 600x400 pixels

```swift
private let floatingApps: Set<String> = [
    "com.apple.systempreferences",
    "com.apple.calculator",
    // ...
]

// Subroles that should float
let floatingSubroles = [
    kAXDialogSubrole,
    kAXSystemDialogSubrole,
    kAXFloatingWindowSubrole,
    "AXSheet",
]
```

### Manual Float Toggle
Windows can be manually floated/unfloated with Hyper+T. Manually floated windows are tracked by PID + title hash and persist until toggled back or the window closes.

## BSP Layout (Master-Stack)

Not true BSP - uses master-stack pattern:
- 1 window: full screen
- 2+ windows: master (50% left), stack (vertical right)

```
┌─────────┬─────────┐
│         │ Stack 1 │
│ Master  ├─────────┤
│         │ Stack 2 │
└─────────┴─────────┘
```

## Focus Border

### Implementation
- Transparent `NSWindow` with custom `NSView`
- `level = .floating` to stay on top
- `ignoresMouseEvents = true` to not interfere
- `collectionBehavior = [.canJoinAllSpaces, .stationary]`

### Coordinate Conversion for Border
```swift
// AX frame → NSWindow frame
let mainScreenHeight = NSScreen.screens[0].frame.height
let nsY = mainScreenHeight - frame.origin.y - frame.height
```

## Timing Constants

All timing values are centralized in `WindowManager.Timing`:

| Constant | Value | Purpose |
|----------|-------|---------|
| `retileDebounce` | 100ms | Coalesce rapid retile requests |
| `activationDelay` | 50ms | Wait for UI to settle after activation |
| `launchDelay` | 300ms | Wait for new app window to appear |

## Common Pitfalls

1. **Don't use frame-based deduplication** for same-app windows in full mode
2. **Always convert coordinates** between NSScreen and AX API
3. **Use `hide()` for single-window apps**, `minimize` for multi-window
4. **Pre-position windows** before activating to avoid flicker
5. **AX Observer memory safety** - Use NotificationCenter for callbacks, not raw pointers

## Future Improvements

- [x] ~~Implement own Hyper key mapping (remove Karabiner dependency)~~ ✓ Done via hidutil + F18
- [ ] Workspace support (virtual desktops)
- [ ] Window gaps per-display
- [ ] Drag-and-drop window positioning

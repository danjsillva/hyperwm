# HyperWM

A minimal, blazing-fast window manager for macOS built in Swift.

## Why?

I've always been a fan of the **Arch + i3** workflow - mouseless navigation, no overlapping windows, everything accessible via keyboard. When I moved to macOS, I tried to replicate that experience:

- **yabai + skhd** - Powerful but required disabling SIP for some features
- **Amethyst** - Good but limited customization
- **Raycast** - Great launcher but not a window manager
- **AeroSpace** - The closest match, used it the longest. But I kept hitting walls - ended up writing bash scripts for behaviors it didn't support natively

After years of workarounds and compromises, I decided to build exactly what I needed: a **tailor-made window manager** focused on performance, written in Swift, with zero dependencies.

## Philosophy

### Performance Obsession
- **Native Swift + Accessibility API** (no AppleScript overhead)
- **Zero polling** - fully event-driven architecture
- **CGEvent tap** for hotkeys (lowest latency possible)
- **~15MB memory** footprint (release build)

### Tailor-Made (Sob Medida)
- Built for one specific workflow, not general-purpose
- No feature bloat - only what's actually used daily
- Every behavior is intentional and tested

### Zero Hacks (Sem Gambiarras)
- Clean, direct implementations only
- No workarounds that mask underlying issues
- If something doesn't work, fix it properly or remove it

## Features

- **Two layout modes**: Full (stacked maximized) and Master-Stack (BSP-like)
- **Hyper key**: Built-in Caps Lock → Hyper (Cmd+Alt+Ctrl+Shift) via hidutil
- **Per-app toggle**: Show/hide apps with single hotkey
- **Brave profile support**: Separate hotkeys for different browser profiles
- **Multi-display**: Move windows between displays, focus displays by number
- **Floating windows**: Auto-detect dialogs/popups + manual toggle
- **Focus border**: Visual indicator for active window
- **Hot reload**: Config changes apply automatically (FSEvents)
- **Menu bar**: Layout, gaps, border, launch at login controls

## Requirements

- macOS 13.0+
- Accessibility permissions

## Installation

```bash
git clone https://github.com/danjsillva/hyperwm.git ~/Projects/hyperwm
cd ~/Projects/hyperwm
swift build -c release

# Create app bundle
mkdir -p ~/Applications/HyperWM.app/Contents/MacOS
cp .build/release/HyperWM ~/Applications/HyperWM.app/Contents/MacOS/

# Launch
open ~/Applications/HyperWM.app
```

## Hotkeys (Hyper + key)

The Hyper key is **Caps Lock** when "Use Built-in Hyper" is enabled, or **Cmd+Alt+Ctrl+Shift** with Karabiner.

| Key | Action |
|-----|--------|
| `E` | Toggle Ghostty |
| `R` | Toggle Slack |
| `A` | Toggle Calendar |
| `S` | Toggle Reminders |
| `D` | Toggle Notes |
| `F` | Toggle Finder |
| `Q` | Toggle Brave (Personal) |
| `W` | Toggle Brave (Work) |
| `Space` | Move window to other display |
| `Tab` | Cycle windows on current display |
| `` ` `` | Toggle layout mode |
| `T` | Toggle float (exclude from tiling) |
| `1` | Focus display 1 |
| `2` | Focus display 2 |

## Configuration

Edit `config.json` to customize bindings:

```json
{
  "gap": 10,
  "useBuiltInHyper": true,
  "bindings": [
    {
      "id": "toggle-terminal",
      "key": "e",
      "modifiers": ["cmd", "alt", "ctrl", "shift"],
      "action": {
        "type": "toggleApp",
        "bundleId": "com.mitchellh.ghostty"
      }
    }
  ]
}
```

### Action Types

| Type | Description | Parameters |
|------|-------------|------------|
| `toggleApp` | Show/hide application | `bundleId` |
| `toggleBraveProfile` | Toggle Brave browser profile | `profile` |
| `cycleWindows` | Cycle through windows on display | - |
| `moveToNextScreen` | Move focused window to next display | - |
| `focusDisplay` | Focus a specific display | `index` (0-based) |
| `toggleFloat` | Toggle window floating state | - |
| `toggleLayoutMode` | Switch between Full/BSP | - |

## Built-in Hyper Key

When enabled, Caps Lock becomes your Hyper key:

- **Hold Caps Lock + key** → Hyper combo
- **Tap Caps Lock** (quick press) → Toggle Caps Lock ON/OFF

Uses `hidutil` (native macOS) to remap at system level. No kernel extensions, no Input Monitoring permission needed.

## Layout Modes

### Full Mode
All windows maximized and stacked. Use hotkeys to switch between apps.

### Master-Stack (BSP)
```
┌─────────┬─────────┐
│         │ Stack 1 │
│ Master  ├─────────┤
│         │ Stack 2 │
└─────────┴─────────┘
```

## Menu Bar

Click the status icon (shows display + mode, e.g., "1F"):

- **Show Active Window Border** - Toggle focus indicator
- **Use Built-In Hyper** - Caps Lock as Hyper key
- **Focus Follows Mouse** - Focus window under cursor
- **Launch at Login** - Auto-start on boot
- **Layout** - Full / BSP
- **Gaps** - 0 / 5 / 10 / 15 / 20 px
- **Reload Config** / **Restart** / **Quit**

## Technical Details

### Architecture Decisions

1. **CGEvent Tap** for hotkeys instead of NSEvent - more reliable, works system-wide
2. **AXUIElement** for window management - no AppleScript subprocess overhead
3. **AX Observer** for window events - zero polling, pure event-driven
4. **Debounced retiling** (100ms) - coalesces rapid window changes

### Coordinate System

macOS has two coordinate systems:
- **NSScreen**: origin at bottom-left
- **Accessibility API**: origin at top-left

All conversions are handled internally.

### Floating Detection

Windows float automatically based on:
- Bundle ID whitelist (System Settings, Calculator, etc.)
- Window subrole (dialogs, sheets)
- Size threshold (< 600x400)
- Manual toggle (Hyper+T)

## License

MIT

# Heimkehr

A tiny macOS menu-bar app that moves every open window onto a chosen display.

## Why it exists

I work with two laptops plugged into the same external monitor. When the
monitor input is switched to the other laptop, the windows of the first
laptop stay "visible" on the (from its point of view still connected)
external display — and vanish from the internal screen. Pulling the HDMI
cable each time is annoying. Heimkehr fixes it with a keystroke.

## Features

- Move every window to the internal MacBook display (`⌃⌥⌘H`, global)
- Cycle every window to the next display
- Move every window to a specific display (one menu entry per monitor)
- Restore the original window layout (`⌃⌥⌘Z`)
- Launch at Login toggle (SMAppService, macOS 13+)
- Localized in English, German, and Dutch
- Pure menu-bar app (no Dock icon)

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15+ (only if you want to build from source)

## Install via Homebrew

```bash
brew tap posalex/tap
brew install --cask heimkehr
```

Heimkehr is ad-hoc signed (no paid Apple Developer certificate), so the
cask removes the quarantine attribute automatically via `xattr -dr
com.apple.quarantine`. If you install the ZIP manually and Gatekeeper
complains, do it yourself:

```bash
xattr -dr com.apple.quarantine /Applications/Heimkehr.app
```

## First-time setup

Heimkehr moves windows of other apps, which requires Accessibility
permission. On first launch it shows a dialog pointing to the right
settings pane.

1. Open System Settings → **Privacy & Security** → **Accessibility**
2. Enable the switch next to `Heimkehr`
3. Quit and relaunch Heimkehr once

Optionally, enable **Launch at Login** from the Heimkehr menu.

## Shortcuts

| Shortcut | Action                                   |
| -------- | ---------------------------------------- |
| `⌃⌥⌘H`   | Move every window to the internal display |
| `⌃⌥⌘Z`   | Restore the original window positions    |

Both shortcuts are global — they work while Heimkehr is in the
background.

## Build from source

```bash
git clone https://github.com/posalex/Heimkehr.git
cd Heimkehr
make build-release
open build/Build/Products/Release/Heimkehr.app
```

Or open `Heimkehr.xcodeproj` in Xcode and hit `⌘R`.

### Makefile targets

| Target         | What it does                                                      |
| -------------- | ----------------------------------------------------------------- |
| `build`        | Debug build                                                       |
| `build-release`| Release build, ad-hoc signed                                      |
| `package`      | ZIP the `.app` into `dist/` (prints SHA-256)                      |
| `bump-patch`   | `1.0.0` → `1.0.1` in `project.pbxproj`                            |
| `bump-minor`   | `1.0.0` → `1.1.0`                                                 |
| `bump-major`   | `1.0.0` → `2.0.0`                                                 |
| `tag`          | Create git tag `v<version>`                                       |
| `release`      | Bump patch, build, package, tag — then prints the `gh` commands   |
| `cask-update`  | Rewrite `~/git/homebrew-tap/Casks/heimkehr.rb` with new version and SHA-256 |
| `clean`        | Remove `build/` and `dist/`                                       |
| `help`         | Show help (default)                                               |

A typical release looks like:

```bash
make release
git push --follow-tags
gh release create v1.0.1 dist/Heimkehr-1.0.1.zip \
  --title 'Heimkehr 1.0.1' --notes 'Release 1.0.1'
make cask-update
cd ~/git/homebrew-tap && git commit -am "heimkehr 1.0.1" && git push
```

## Known limitations

- **Minimized** and **fullscreen** windows cannot be moved — that's a
  macOS Accessibility API limitation, not this app's. Restore the
  window first, then run Heimkehr.
- **Electron/Chrome windows** occasionally accept the first position
  change only after a second attempt. Heimkehr writes position → size
  → position to work around this.
- The snapshot uses `(pid, windowIndex)` as the key. If a window is
  closed between snapshot and restore, the mapping shifts.

## Architecture

- `HeimkehrApp.swift` — SwiftUI entry point, hands off to the delegate
- `AppDelegate.swift` — status-item menu, global hotkeys (Carbon)
- `WindowManager.swift` — per-window AX logic, snapshot/restore
- `LaunchAtLogin.swift` — wrapper around `SMAppService.mainApp`
- `Info.plist` — `LSUIElement = true` (no Dock icon)
- `Heimkehr.entitlements` — sandbox off (required for cross-app AX)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

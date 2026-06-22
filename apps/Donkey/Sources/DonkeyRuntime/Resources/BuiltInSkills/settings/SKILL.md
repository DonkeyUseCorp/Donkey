# System Settings

id: settings
description: Change macOS settings with defaults/networksetup/osascript instead of clicking through System Settings; deep-link a pane only when the user must finish there.
tags: settings, preferences, system, local-app
keywords: settings, preferences, dark mode, wifi, bluetooth, sound, volume, display, dock, wallpaper, notifications
apps: System Settings, System Preferences, com.apple.systempreferences
tools: shell_exec, app_skill

System Settings' GUI is slow to drive and its Accessibility tree is uneven. An expert changes settings from the command line; state-changing commands ask for one-time or always-allow consent, so propose them directly.

## Read current state
- `defaults read com.apple.dock autohide`, `defaults read NSGlobalDomain AppleInterfaceStyle` (errors when light mode).
- macOS version: `sw_vers`. Storage: `df -h /`. Battery and charging state: `pmset -g batt`.
- Pending software updates: `softwareupdate -l --no-scan` (fast, cached) or `softwareupdate -l` (slow scan — pass timeoutSeconds 60).
- Network: `networksetup -getairportpower en0`, `networksetup -getinfo Wi-Fi`.
- Bluetooth: `system_profiler SPBluetoothDataType` lists power state and connected devices.
- Volume: `osascript -e 'output volume of (get volume settings)'`.
- Low Power Mode state: `pmset -g | grep lowpowermode`.

## Change settings
- Dock: `defaults write com.apple.dock autohide -bool true` then `killall Dock` to apply.
- Dark mode: `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'`.
- Volume: `osascript -e 'set volume output volume 40'`; mute: `osascript -e 'set volume with output muted'`.
- Wi-Fi: `networksetup -setairportpower en0 off`.
- Wallpaper: `osascript -e 'tell app "System Events" to set picture of every desktop to "/path/to/image.jpg"'`.
- Low Power Mode: `pmset -a lowpowermode 1` (0 to turn off).
- Many `defaults` changes need the owning process restarted (`killall Dock`, `killall Finder`, `killall SystemUIServer`) to take effect — include it.

## Do Not Disturb / Focus
- There is no supported command-line toggle for Focus modes. If the user has a Shortcuts shortcut that toggles a Focus, run it: `shortcuts run "Set Focus"` (list available ones with `shortcuts list`). Otherwise drive Control Center through the GUI (click the Control Center menu-bar item, then the Focus tile) — or tell the user it needs a one-time Shortcuts setup for reliable automation.

## When only the GUI will do
- Deep-link straight to a pane rather than navigating: `open "x-apple.systempreferences:com.apple.preference.security"` (Privacy & Security), `…com.apple.preference.notifications`, `…com.apple.preference.displays`.
- Toggles that require user authentication (privacy permissions, FileVault, Touch ID) must be flipped by the user; open the right pane, tell them exactly what to click, and wait.

## Boundaries
- Privacy/TCC, security, login, and keychain settings are high-risk: every command asks, nothing is remembered. Never edit the TCC database.

## Verify
- Re-read the value you changed (`defaults read …`, `networksetup -get…`) and confirm the new value before completing.

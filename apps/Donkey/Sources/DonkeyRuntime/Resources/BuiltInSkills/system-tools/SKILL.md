# System Tools

id: system-tools
description: Operate macOS like an expert power user through shell_exec — find files, launch and quit apps, read state, and change settings with native command-line tools instead of screenshots.
tags: shell, system, files, settings, power-user, terminal, local-app
keywords: find, file, open, launch, quit, settings, defaults, battery, wifi, clipboard, finder, spotlight, version, dark mode, volume, network
tools: shell_exec, apps_list

Use `shell_exec` as the first choice for anything an expert terminal user would do without touching the GUI. Read-only commands run immediately; state-changing ones ask the user for one-time or always-allow consent, so propose them directly rather than falling back to clicking. Keep each command to a single line.

## Find and inspect files
- Spotlight search by name or content: `mdfind -name report.pdf`, `mdfind "kMDItemTextContent == '*invoice*'"`.
- Newest / largest in a folder: `ls -t ~/Downloads/*.pdf | head -1`, `ls -S ~/Downloads | head`.
- Walk a tree: `find ~/Documents -name '*.key' -mtime -7`.
- Read metadata or contents: `mdls file.pdf`, `stat -f '%Sm %N' file`, `cat file`, `head -50 file`.

## Open, launch, and quit
- Open a file in its default app: `open ~/Downloads/report.pdf`.
- Launch or focus an app: `open -a "Spotify"`; reveal in Finder: `open -R ~/file`; open a URL: `open https://example.com`.
- Quit an app cleanly: `osascript -e 'quit app "Safari"'`; force a hung app: `killall Safari`.
- List installed/running apps to target exact names: prefer the `apps_list` tool.

## Read system and app state
- Battery / power: `pmset -g batt`. Hardware/software: `system_profiler SPHardwareDataType`, `sw_vers`.
- Disk: `df -h`. Network: `networksetup -getairportpower en0`, `networksetup -getinfo Wi-Fi`.
- A preference's current value: `defaults read com.apple.dock autohide`.
- Tool availability/version (to decide what's possible): `which gh`, `python3 --version`.

## Change settings (asks for consent first)
- App/UI preferences: `defaults write com.apple.dock autohide -bool true` then `killall Dock` to apply.
- Dark mode: `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'`.
- Wi-Fi power: `networksetup -setairportpower en0 off`.
- Clipboard: `pbcopy < file.txt`, `pbpaste`. Image convert/resize: `sips -Z 800 image.png`.

## Boundaries
- Security- and privacy-sensitive changes (TCC/privacy, FileVault, login window, passwords, keychain) and destructive or privileged commands (`sudo`, `rm`, `dd`, piping into a shell) ask every time and are never remembered.
- Use the GUI (ax.observe / vision.capture and clicks) only when there is no system-tool equivalent — canvas, Electron, or proprietary interfaces.

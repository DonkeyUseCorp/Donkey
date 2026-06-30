# System Tools

id: system-tools
description: Operate macOS like an expert power user through shell_exec — find files, launch and quit apps, read state, and change settings with native command-line tools instead of screenshots.
tags: shell, system, files, settings, power-user, terminal, local-app
keywords: find, file, open, launch, quit, settings, defaults, battery, wifi, clipboard, finder, spotlight, version, dark mode, volume, network
tools: shell_exec, apps_list

Use `shell_exec` as the first choice for anything an expert terminal user would do without touching the GUI. Read-only commands run immediately; state-changing ones ask the user for one-time or always-allow consent, so propose them directly rather than falling back to clicking. Keep each command to a single line.

## Drive Mac apps with AppleScript, not URL schemes
- To read or change content inside a Mac app — create a note, read mail, add a calendar event, look up a contact, get the current browser tab — drive the app with AppleScript: `osascript -e 'tell application "App" to …'`. Look the app's skill up first (`app_skill`) for the exact script.
- NEVER invent an app URL scheme such as `notes://` or `mobilenotes://create?…` to do this. Those schemes are not registered on macOS and silently fail with "No application knows how to open URL".
- Use `open` only to open files, folders, and web URLs, or to launch an app by name (`open -a "App"`). Not to manipulate an app's content.

## Shell safety: zsh globs and parentheses
- Commands run under `zsh`, where a filename glob that matches nothing ABORTS the whole command with `no matches found`. To find the newest file of several types, do NOT glob multiple extensions — list by time and filter with grep: `ls -t ~/Downloads | grep -iE '\.png$|\.jpg$|\.jpeg$|\.heic$|\.gif$' | head -1`.
- Never read `no matches found` as "no such files exist" — it means the glob was too strict. Widen the search (the `ls | grep` form) and retry.
- Keep parentheses out of commands. The safety classifier treats `(`/`)` (subshells, `find \( \)`, glob qualifiers like `(N)`) as separate commands and will prompt for approval on an otherwise read-only command. The `ls … | grep -iE` form above is parenthesis-free and runs instantly.

## Find and inspect files
- Check the obvious places FIRST: `ls -t ~/Desktop ~/Downloads ~/Documents .`. A file the user just made, downloaded, or moved is usually here, and this beats Spotlight for fresh files.
- `mdfind` searches the Spotlight INDEX, which lags reality: a file created or moved seconds ago may not be indexed yet, so `mdfind` can return nothing — or a stale OLDER copy in a different folder. Don't trust an `mdfind` hit as "the" file when the direct `ls` above found the named file in a user folder; prefer that copy.
- Spotlight search by name or content (after the direct checks): `mdfind -name report.pdf`, `mdfind "kMDItemTextContent == '*invoice*'"`.
- Newest of one type / largest in a folder: `ls -t ~/Downloads/*.pdf | head -1`, `ls -S ~/Downloads | head`. For several types at once, use the `ls … | grep -iE` form from Shell safety above.
- Walk a tree, but always SCOPED to a folder: `find ~/Documents -name '*.key' -mtime -7`. Never run a bare `find .` or `find ~` — from home it walks the whole tree and times out before it reaches anything.
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

## Change settings (asks for consent first)
- App/UI preferences: `defaults write com.apple.dock autohide -bool true` then `killall Dock` to apply.
- Dark mode: `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'`.
- Wi-Fi power: `networksetup -setairportpower en0 off`.
- Clipboard: `pbcopy < file.txt`, `pbpaste`. Image convert/resize: `sips -Z 800 image.png`.

## More expert one-liners
- Open an address in Maps: `open "maps://?q=1%20Apple%20Park%20Way"` (URL-encode the address).
- Screenshot to a file: `screencapture -x ~/Desktop/shot.png` (whole screen, no sound).
- Top memory/CPU processes (instead of Activity Monitor): `ps aux -m | head -8`, `ps aux -r | head -8`.
- Text file conversions: `textutil -convert pdf notes.rtf`, `textutil -convert txt page.html`.
- Run a user Shortcuts shortcut: `shortcuts run "Name"`; list them: `shortcuts list`.
- Text the screen selection: press Cmd+C first (keyboard.press key=c modifiers=command on the focused app), then read it with `pbpaste`.

## Boundaries
- Security- and privacy-sensitive changes (TCC/privacy, FileVault, login window, passwords, keychain) and destructive or privileged commands (`sudo`, `rm`, `dd`, piping into a shell) ask every time and are never remembered.
- Use the GUI (ax.observe / vision.capture and clicks) only when there is no system-tool equivalent — canvas, Electron, or proprietary interfaces.

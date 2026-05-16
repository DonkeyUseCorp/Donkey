# macOS Accessibility

## Goal

Use macOS Accessibility as a PhoneAgent-like tree/action backend for Mac apps, window management, setup flows, and non-frame-critical UI control.

This complements the fast screenshot/input loop. It does not replace low-latency visual gameplay perception.

## Feasibility

Yes, macOS has a system Accessibility API based around `AXUIElement`.

Apple describes `AXUIElement` as the object assistive applications use to communicate with and control accessible applications running in macOS. The API can expose attributes, children, positions, actions, focused elements, and notifications.

Useful Apple references:

- `AXUIElement.h`: https://developer.apple.com/documentation/applicationservices/axuielement_h
- `AXUIElement`: https://developer.apple.com/documentation/applicationservices/axuielement
- `AXUIElementCreateApplication`: https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication
- `AXUIElementCopyElementAtPosition`: https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- Accessibility Inspector: https://developer.apple.com/documentation/accessibility/accessibility-inspector

## Best Uses

Use macOS Accessibility for:

- finding the iPhone Mirroring window
- reading window title, position, size, and focus state
- bringing a target app/window forward
- detecting native dialogs
- detecting payment, login, permission, or system prompts
- pressing native buttons and menu items
- reading labels and values in normal Mac apps
- verifying that an action changed the UI
- setup and recovery outside live gameplay

For iPhone Mirroring specifically:

- Accessibility can help control the Mac-side iPhone Mirroring app and window.
- It probably cannot see the internal game objects inside an iPhone game.
- Live gameplay should still rely on screenshot perception and synthetic taps/swipes.

## Poor Uses

Do not rely on macOS Accessibility for:

- per-frame gameplay decisions
- canvas/WebGL game internals
- iPhone game internals inside the mirrored video stream
- highly animated visual state
- latency-critical dodge/jump/shoot loops
- apps that expose incomplete or stale accessibility trees

## Supported Read-Only Snapshot Boundary

Donkey now supports bounded, read-only Accessibility snapshots for the manual target context capture milestone.

Supported behavior:

- check process Accessibility trust without prompting
- resolve a selected target window by pid, title, focus, and frame metadata when possible
- serialize a shallow tree with role, title/label, value summary, frame, enabled/focused state, and available action names
- cap depth, children per node, total nodes, and text length
- write trusted snapshots to the run artifact store under `accessibility/`
- append a clear partial-run event when Accessibility trust is missing

Current boundary:

- The snapshot service records action names but does not perform actions.
- Full app navigation, menu selection, value setting, focus changes, and setup/recovery flows remain future work.

## Operating Loop

Use the same inspect-act-verify pattern as PhoneAgent:

```text
1. Get the active app/window accessibility tree.
2. Identify a safe target element by role, title, label, value, or frame.
3. Perform one action.
4. Re-read the tree or screenshot.
5. Verify the result.
6. Stop on unknown, sensitive, payment, login, or system screens.
```

Rules:

- Use one action at a time.
- Do not queue actions against stale trees.
- Prefer accessibility actions for native controls.
- Fall back to synthetic mouse/keyboard only when needed.
- Keep AX calls outside the hot gameplay loop unless measured under budget.

## Action Surface

Expose a backend similar to the iOS control prompt:

```text
get_tree(app_or_window)
get_focused_window()
get_element_at_position(x, y)
perform_action(element_id, action)
set_value(element_id, value)
tap_element(element_id)
focus_window(window_id)
get_window_rect(window_id)
stop()
```

Bridge into the synthetic controller:

```text
semantic_action -> accessibility action
semantic_action -> synthetic mouse/keyboard action
semantic_action -> screenshot/gameplay action
```

## Permissions

The process needs Accessibility trust.

Use:

```text
AXIsProcessTrusted()
AXIsProcessTrustedWithOptions(...)
```

If not trusted, show a setup path:

```text
System Settings -> Privacy & Security -> Accessibility
```

## iPhone Mirroring Workflow

Use macOS Accessibility to support iPhone Mirroring:

1. find the iPhone Mirroring app/window
2. read its window bounds
3. focus the window before input
4. detect if the window moved or resized
5. detect Mac-side dialogs or disconnection state
6. hand the content rectangle to screenshot capture
7. hand input coordinates to the synthetic controller

The AX tree helps with the container. The screenshot/model loop handles the game content.

## Latency And Reliability

Track:

- ax_tree_ms
- ax_action_ms
- ax_verify_ms
- tree_stale_count
- action_failed_count
- inaccessible_element_count
- fallback_to_synthetic_input_count

Accessibility APIs can block or return stale/incomplete data if the target app is busy or not fully accessible. Keep timeouts short and do not let AX calls block the reflex loop.

## First Milestones

Completed for the manual capture milestone:

1. Check Accessibility trust status from the runtime capture path.
2. Resolve a target app/window and dump bounded read-only AX attributes.
3. Store shallow AX snapshots as local run artifacts.

Remaining future milestones:

1. Find the iPhone Mirroring window and read its bounds for calibration.
2. Detect focus loss before sending synthetic input.
3. Add an accessibility-backed window guard to the iPhone gameplay loop.
4. Add tree/action/verify support for native Mac setup dialogs.

## Acceptance Criteria

- The system can identify the active target window through Accessibility.
- The system can refuse input when the wrong window is focused.
- The system can read iPhone Mirroring window bounds for calibration.
- Accessibility calls are timed and never block the gameplay hot path.
- Native Mac dialogs can be detected as safety stops.

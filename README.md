# Snip

A small, native macOS screenshot tool that copies the look and workflow of the
Windows 11 Snipping Tool: **one window**, click **New**, drag, done.

Written in a single Swift file (AppKit), built with `swiftc` — no Xcode project required.

## Features

- **One window.** New and the mode/delay menus on the left, Copy and Save on the right.
- **Snip modes:** Rectangle, Window (hover to highlight), Monitor (the display under your cursor), Free-form.
- **Delay:** none, 3, 5 or 10 seconds.
- **Markup & editing:** pen, highlighter, **eraser** (drag over a stroke to remove it), **crop** (drag the area to keep), color, thickness, undo.
- **Private by default:** snips live in memory only. Closing the window discards them; nothing is written to disk unless you click **Save**.
- **Menu bar app:** click the scissors icon to open the window, right-click for New / Quit.
- **Global hotkey:** `Control` + `Shift` + `S`.
- Dark mode support. Saved/copied images are full Retina resolution.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`) — provides `swiftc` and `codesign`

## Build & install

```sh
git clone https://github.com/ibtpadmanabhan/snip-mac.git
cd snip-mac
./build.sh            # builds ./Snip.app
./build.sh install    # also copies it to /Applications
open /Applications/Snip.app
```

## First run: Screen Recording permission

macOS requires permission to capture the screen.

1. Launch Snip and click **New** — macOS will prompt you (or open
   **System Settings → Privacy & Security → Screen Recording**).
2. Enable **Snip**.
3. Quit and reopen Snip (macOS requires a restart of the app after granting).

If you move or rebuild the app and macOS keeps asking again, remove old *Snip* entries
from the Screen Recording list and add `/Applications/Snip.app` again. The build script
signs the app with a stable designated requirement (`identifier "com.local.snip"`) so the
permission survives rebuilds; if you change the bundle identifier in `build.sh`, update that too.

## Usage

| Action | How |
|---|---|
| Start a snip | **New** button, menu-bar menu, or `⌃⇧S` |
| Cancel selection | `Esc` |
| Copy | Copy button or `⌘C` |
| Save | Save button or `⌘S` (choose where to save) |
| Undo (stroke, erase or crop) | Undo button or `⌘Z` |
| Close and discard | Close the window (`⌘W`) |

## How it works

- Selection overlay: borderless, transparent windows on every display.
- Window mode: `CGWindowListCopyWindowInfo` to find the window under the cursor.
- Capture: the system `screencapture` tool for the chosen region, loaded straight into memory (the temporary file is deleted immediately).
- Free-form: captures the bounding box, then masks pixels outside the drawn path.
- Hotkey: Carbon `RegisterEventHotKey` (no Accessibility permission needed).

## Known limitations

- No ruler or text tool yet. The eraser removes whole strokes (not pixels), and crop applies when you release the mouse (use undo to revert).
- The delay runs *before* the selection overlay appears (as in Windows), but opening the overlay can dismiss open menus, so capturing transient menus is unreliable.
- Ad-hoc signed, not notarized. Build from source rather than distributing the binary.

## Contributing

Issues and pull requests are welcome. The whole app lives in `main.swift`.

## License

[MIT](LICENSE)

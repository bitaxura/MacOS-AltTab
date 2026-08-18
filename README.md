# TrackpadGestures (MacOS-AltTab)

A lightweight, high-performance native macOS utility that brings **Windows-style Alt-Tab window switching**, **2D spatial multitouch trackpad gestures**, and **middle-click emulation** to macOS.

Built entirely in Swift using native macOS APIs (`MultitouchSupport`, `Accessibility`, `CoreGraphics`), running quietly as a menu bar accessory app with zero external dependencies and near-zero resource usage.

---

## Features

### Windows-Style Alt-Tab Window Switcher
macOS by default switches between *applications*, not individual *windows*. TrackpadGestures provides a true individual window switcher:
- **True MRU Z-Order**: Lists all visible and active windows in Most Recently Used (MRU) order.
- **Rich Window Cards**: Displays high-resolution app icons, cleaned window titles, and contextual subtitles (e.g., Safari/Chrome profile badges like *Personal* or *Work*, and IDE project/file badges).
- **Grid Layout with Mouse & Keyboard Support**: Smart multi-column grid layout with smooth hover effects, click-to-activate, and arrow key navigation.
- **Multi-Monitor Aware**: Automatically centers the switcher overlay on the screen containing your active mouse cursor.
- **Window Management on the Fly**: Close windows (<kbd>⌘ Cmd</kbd> + <kbd>W</kbd>) or quit apps (<kbd>⌘ Cmd</kbd> + <kbd>Q</kbd>) directly from the switcher overlay.
- **Unminimize & Raise**: Automatically restores minimized windows and brings the selected window directly to the front.

---

### Multitouch Trackpad Gestures
Directly connects to Apple's private `MultitouchSupport.framework` to read raw per-finger contact frames:
- **3-Finger Spatial Swipe -> Window Switcher**:
  - Swipe 3 fingers horizontally to trigger the window switcher overlay.
  - Once active, swipe in any direction (**up, down, left, right, diagonally, or around**) to navigate across the card grid.
  - Direction mapping follows natural spatial coordinates: swipe up moves to the row above, swipe down moves to the row below, swipe right moves right, swipe left moves left.
  - Non-wrapping boundary clamping prevents overshooting and accidental loopback.
  - Lift fingers to immediately activate the selected window.
- **3-Finger Tap -> Native Middle Click**:
  - Tap with 3 fingers anywhere on the trackpad to trigger a native Middle Click (`button: 2`).
  - Perfect for opening links in background tabs, closing browser tabs, and panning in 3D/CAD or design software.
- **Conflict Prevention & Isolation**:
  - Isolated from 4-finger system gestures (Mission Control / Space Switch).
  - Rejects vertical scrolling drift during initial tap recognition to prevent accidental triggers during normal browsing.

---

### Low-Latency Keyboard Interception
- **Cmd + Tab Override**: Intercepts <kbd>⌘ Cmd</kbd> + <kbd>Tab</kbd> and <kbd>⇧ Shift</kbd> + <kbd>⌘ Cmd</kbd> + <kbd>Tab</kbd> via low-level `CGEventTap` (`.cghidEventTap` / `.cgSessionEventTap`).
- **Keyboard Shortcuts in Switcher**:
  | Shortcut | Action |
  | :--- | :--- |
  | <kbd>⌘ Cmd</kbd> + <kbd>Tab</kbd> | Step forward to next window |
  | <kbd>⇧ Shift</kbd> + <kbd>⌘ Cmd</kbd> + <kbd>Tab</kbd> | Step backward to previous window |
  | <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | Navigate window cards in 2D grid |
  | <kbd>⌘ Cmd</kbd> + <kbd>W</kbd> | Close the selected window |
  | <kbd>⌘ Cmd</kbd> + <kbd>Q</kbd> | Quit the selected application |
  | <kbd>Return</kbd> / <kbd>Space</kbd> / Release <kbd>⌘</kbd> | Focus & switch to selected window |
  | <kbd>Esc</kbd> | Dismiss switcher without switching |

---

## Installation & Building

### Prerequisites
- macOS 13.0 (Ventura) or later (fully compatible with macOS 14 Sonoma & macOS 15 Sequoia).
- Xcode Command Line Tools (`xcode-select --install`).

### Build from Source

1. Clone this repository:
   ```bash
   git clone https://github.com/bitaxura/MacOS-AltTab.git
   cd MacOS-AltTab
   ```

2. Run the build script:
   ```bash
   ./build.sh
   ```
   The build script compiles the Swift sources and produces an ad-hoc signed app bundle at `build/TrackpadGestures.app`.

3. Move the application to your `/Applications` folder:
   ```bash
   mv build/TrackpadGestures.app /Applications/
   ```

4. Launch the application:
   ```bash
   open /Applications/TrackpadGestures.app
   ```

---

## Required macOS Permissions

To inspect window titles, intercept gestures, and manage focus, macOS requires granting two permissions in **System Settings -> Privacy & Security**:

### 1. Accessibility (`AXIsProcessTrusted`)
- **Why**: Needed to retrieve open window hierarchies, read window titles, simulate middle-click events, and focus/raise/close target windows.
- **How to enable**:
  1. Open **System Settings** -> **Privacy & Security** -> **Accessibility**.
  2. Click the `+` button and add `TrackpadGestures.app` from `/Applications/` (or enable its toggle switch).

### 2. Input Monitoring
- **Why**: Needed for `CGEventTap` to intercept <kbd>⌘ Cmd</kbd> + <kbd>Tab</kbd> before the default Dock switcher, and read raw trackpad touch frames.
- **How to enable**:
  1. Open **System Settings** -> **Privacy & Security** -> **Input Monitoring**.
  2. Add / enable `TrackpadGestures.app`.

> **Note on App Updates**: If you rebuild the application and permissions stop functioning, remove `TrackpadGestures` from both Accessibility and Input Monitoring lists using the `-` button and re-add it.

---

## Project Structure

```
TrackpadGestures/
├── build.sh                  # Build & ad-hoc codesign script
├── Info.plist                # App bundle metadata (LSUIElement = true)
├── README.md                 # Project documentation
└── Sources/
    ├── main.swift            # App entry point, lifecycle & status bar item
    ├── MultitouchBridge.h    # C header bridging Apple's MultitouchSupport.framework
    ├── GestureEngine.swift   # Per-finger trackpad contact tracking & 2D gesture recognition
    ├── SwitcherController.swift # Coordinator for switcher lifecycle & window actions
    ├── SwitcherPanel.swift   # NSPanel UI, frosted glass HUD & interactive card views
    ├── WindowEngine.swift    # Window discovery, filtering, title cleanup & MRU z-ordering
    ├── KeyInterceptor.swift  # Low-level CGEventTap for keyboard shortcuts (Cmd+Tab, etc.)
    ├── ActionPoster.swift    # Native CGEvent synthesis (middle click, keystrokes)
    └── WindowPreview.swift   # Preview capture interface stub
```

---

## Configuration & Tunables

You can customize behavior directly in the source files before running `./build.sh`:

- **Swipe Sensitivity & Tap Thresholds** ([`GestureEngine.swift`](Sources/GestureEngine.swift)):
  - `swipeActivationThreshold`: Trackpad distance to activate switcher (default: `0.035`).
  - `tapMaxDrift`: Maximum finger drift allowed during a tap (default: `0.055`).
  - `tapMaxDuration`: Max duration for a 3-finger touch to register as a middle-click tap (default: `0.40s`).
  - `switchStepDistanceX`: Horizontal trackpad distance per card column (default: `0.075`).
  - `switchStepDistanceY`: Vertical trackpad distance per card row (default: `0.085`).
- **Debug Logging**:
  - Run the app from terminal with `TPG_DEBUG=1 /Applications/TrackpadGestures.app/Contents/MacOS/TrackpadGestures` to see real-time multitouch frame logs.

---

## Troubleshooting

- **Gestures conflict with macOS 3-finger gestures**:
  - If you have macOS system gestures bound to 3 fingers (e.g. *Look up & data detectors* or *Mission Control*), go to **System Settings -> Trackpad -> More Gestures** and change system gestures to 4 fingers or disable 3-finger look up.
- **Switcher does not appear on Cmd+Tab**:
  - Ensure **Input Monitoring** permission is granted to `TrackpadGestures.app`.
  - Check if another keyboard manager (e.g. Karabiner-Elements) is intercepting <kbd>Cmd</kbd> + <kbd>Tab</kbd> before event taps.
- **Window titles are missing or generic**:
  - Ensure **Accessibility** permission is enabled in System Settings.

---

## License

This project is licensed under the [MIT License](LICENSE) (or open for personal modification). Feel free to fork, customize, and contribute!

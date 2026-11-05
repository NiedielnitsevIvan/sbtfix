# Changelog

## Unreleased

- Equalizer submenu with the WH-1000XM4 presets. Other v1 models may work too, but aren't tested.
- Check for Updates installs the latest GitHub release. It only goes online when you click it.

## 1.1.0

- "On connect" startup mode: switch to Off or Ambient Sound as soon as the headphones connect
  (WH-1000XM4 always power on in Noise Cancelling)
- Ambient level and Focus on Voice are remembered across launches
- Much lower idle CPU use: Bluetooth is polled every 30 s instead of 5 s, only while disconnected,
  and repeated status checks no longer trigger UI updates
- The init request is repeated when the headphones miss it right after connecting
- The Speak-to-Chat toggle no longer flips back for a moment after a click
- The menu opens at once: a plain status-item menu replaces MenuBarExtra, which often took
  1.5–3 s to open after the app had been idle
- "On connect" submenu, and Retry shown only while not connected
- Redesigned panel: mode buttons in a 2×2 grid of Liquid Glass tiles on macOS 26 and later,
  narrower, and its height follows the content
- App icon in the style of 1960–80s Ukrainian trademarks
- Speak-to-Chat toggle on WH-1000XM4: its reply to the status request was ignored, so the
  toggle never appeared
- Screenshots of every state in the README, in light and dark mode
- `sbtfix --screenshots <dir>` regenerates them, captured from the real menu
- Building needs Xcode 26 or later (macOS 26 SDK); the app still runs on macOS 14
- Release notes are now built from this changelog automatically

## 1.0.0

First public release.

- Menu-bar control of Noise Cancelling, Ambient Sound and Off, plus Wind Noise Reduction on
  models that have it
- Ambient level slider and Focus on Voice
- Speak-to-Chat toggle
- Battery level with charging indicator; left, right and case for earbuds
- Supports the v1 and v2 Sony protocols with automatic detection: WH-1000XM2–XM6,
  WF-1000XM3–XM5, LinkBuds S, WF-C/WH-CH series, ULT WEAR and more
- Shows only the features the connected model supports
- Stays in sync with the buttons on the headphones
- Reconnects automatically, including after Bluetooth is switched back on

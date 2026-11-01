# sbtfix

A small native macOS menu-bar app for controlling Sony headphones and earbuds (WH-1000XM4,
XM5, XM6, WF-1000XM4/XM5, LinkBuds S and more): switch between **Noise Cancelling**,
**Ambient Sound** and **Off**, adjust the ambient level, toggle **Focus on Voice** and
**Speak-to-Chat**, and check the battery. You no longer need to reach for your phone.

Sony doesn't publish a Mac version of its Sound Connect / Headphones Connect app. sbtfix
talks to the headphones directly over Bluetooth using the same protocol the phone app uses.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ambient-dark.png"><img src="docs/screenshots/ambient-light.png" alt="sbtfix menu showing Ambient Sound mode with the level slider" width="320"></picture>
</p>

## Features

- One click to switch between Noise Cancelling, Ambient Sound and Off, plus Wind Noise
  Reduction on models that have it
- Ambient level slider (1–20) and Focus on Voice
- Speak-to-Chat on/off
- Battery level with a charging indicator; left, right and case for earbuds
- Detects the model and protocol generation automatically, and only shows what your model
  supports
- The menu-bar icon shows the current mode
- Stays in sync when you use the buttons on the headphones
- Reconnects automatically when the headphones connect
- No Dock icon, no background daemons, no network access, no dependencies

## Screenshots

<table>
  <tr>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/noise-cancelling-dark.png"><img src="docs/screenshots/noise-cancelling-light.png" alt="Noise Cancelling" width="300"></picture><br><sub><b>Noise Cancelling</b></sub></td>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ambient-dark.png"><img src="docs/screenshots/ambient-light.png" alt="Ambient Sound" width="300"></picture><br><sub><b>Ambient Sound</b>: level slider and Focus on Voice</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/off-dark.png"><img src="docs/screenshots/off-light.png" alt="Off" width="300"></picture><br><sub><b>Off</b></sub></td>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/wind-xm4-dark.png"><img src="docs/screenshots/wind-xm4-light.png" alt="Wind Noise Reduction on WH-1000XM4" width="300"></picture><br><sub><b>Wind Reduction</b>: added on models that support it (here a WH-1000XM4)</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/earbuds-dark.png"><img src="docs/screenshots/earbuds-light.png" alt="Earbuds battery" width="300"></picture><br><sub><b>Earbuds</b>: left, right and case battery (WF-1000XM5)</sub></td>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/waiting-dark.png"><img src="docs/screenshots/waiting-light.png" alt="Waiting for headphones" width="300"></picture><br><sub><b>Waiting</b>: headphones not connected to the Mac yet</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/connecting-dark.png"><img src="docs/screenshots/connecting-light.png" alt="Connecting" width="300"></picture><br><sub><b>Connecting</b></sub></td>
    <td align="center" valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/bluetooth-off-dark.png"><img src="docs/screenshots/bluetooth-off-light.png" alt="Bluetooth off" width="300"></picture><br><sub><b>Bluetooth off</b>: reconnects by itself when it's back on</sub></td>
  </tr>
</table>

## Compatibility

Sony uses two protocol generations. sbtfix detects which one your device uses when it
connects.

| Model | Protocol | Modes | Status |
|-------|----------|-------|--------|
| WH-1000XM5 | v2 | NC · Ambient · Off | ✅ Tested (fw 2.4.1) |
| WH-1000XM6 | v2 | NC · Ambient · Off | 🟡 Expected to work |
| WH-1000XM4 | v1 | NC · Wind · Ambient · Off | 🟡 Expected to work |
| WH-1000XM3, WH-1000XM2 | v1 | NC · Wind · Ambient · Off | 🟡 Expected to work |
| WF-1000XM5, WF-1000XM4 | v2 | NC (· Wind on XM4) · Ambient · Off | 🟡 Expected to work |
| WF-1000XM3 | v1 | NC · Wind · Ambient · Off | 🟡 Expected to work |
| WF-SP800N | v1 | NC · Ambient · Off | 🟡 Expected to work |
| LinkBuds S, WF-C700N, WF-C710N, WH-CH720N, ULT WEAR | v2 | NC · Ambient · Off | 🟡 Expected to work |
| WF-C510 | v2 | Ambient · Off | 🟡 Expected to work |
| WI-SP600N | v1 | NC · Wind · Ambient · Off | 🟡 Expected to work |
| WF-C500, WI-C100, LinkBuds | auto | No ambient control; battery only | 🟡 Expected to work |

🟡 means the protocol support is built in, based on
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)'s research, but nobody has
confirmed it on a Mac yet. If you own one of these, please send a
[device report](../../issues/new?template=device-report.md), even if it just says "works".
Other Sony models aren't listed but will probably partly work.

Requires **macOS 14 Sonoma or later**.

## Install

### Download

1. Download `sbtfix.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `sbtfix.app` to `/Applications`.
3. The app isn't notarized, so macOS will block it the first time. Right-click the app, choose
   **Open**, then click **Open** again. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/sbtfix.app
   ```
4. Click **Allow** when macOS asks for Bluetooth access.

### Build from source

You need Xcode 15 or later, or the Swift 5.9+ command-line tools.

```sh
git clone https://github.com/htsecurity/sbtfix.git
cd sbtfix
./build.sh            # builds build/sbtfix.app
./build.sh --install  # also copies it to /Applications
```

To start sbtfix at login, add it under **System Settings → General → Login Items**.

## Usage

1. Pair and connect your headphones in macOS Bluetooth settings as usual.
2. Click the headphones icon in the menu bar.

If the app says *Waiting for headphones to connect…*, check that the headphones are connected
in macOS, not just paired. It connects on its own when they appear.

## Troubleshooting

- **"No paired Sony headphones found"**: the app finds devices by name (`WH-…`, `WF-…`, `WI-…`,
  `LinkBuds…`, `ULT WEAR`). If you renamed your headphones, rename them back.
- **A mode or feature you expect is missing**: the app shows only what your model supports, and
  hides Speak-to-Chat if the device doesn't respond to it. If that's wrong for your model,
  please open a device report with a debug log.
- **Stuck on "Connecting…"**: turn the headphones off and on, or click **Retry**. If the Sony
  phone app is connected at the same moment, it can hold the control channel.
- **Nothing happens after granting Bluetooth permission**: quit and relaunch the app once.
- **Changing Speak-to-Chat from the app doesn't play a voice prompt.** That's normal. The
  headphones only announce it when you use the two-finger gesture on the earcup.
- **Debug logs**: the app logs all Bluetooth traffic at debug level:
  ```sh
  /usr/bin/log stream --level debug --predicate 'subsystem == "io.github.htsecurity.sbtfix"'
  ```
  Including this output makes bug reports much easier to act on.

## How it works

The headphones expose a Bluetooth RFCOMM (serial) service. Over it, they speak a simple framed
binary protocol. sbtfix opens that channel with `IOBluetooth`, sends small commands, and
listens for notifications. [docs/PROTOCOL.md](docs/PROTOCOL.md) documents the framing and every
command the app uses.

```
Sources/
  SonyProtocol/       Pure Swift: framing, escaping, command builders, event parser (unit-tested)
    DeviceProfile.swift         Per-model features (wind reduction, earbuds, …)
  sbtfix/
    HeadphoneController.swift   IOBluetooth RFCOMM connection, command queue, state
    SbtfixApp.swift        Status-item menu hosting the SwiftUI panel
Tests/SonyProtocolTests/        Protocol tests (swift test)
```

## Contributing

Contributions are welcome, especially reports from other Sony models and support for more
features (EQ, DSEE, multipoint, and so on). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

The protocol knowledge comes from the reverse-engineering work in
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) and
[SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient). Thank you to
everyone who worked on them.

## Disclaimer

This is an unofficial project. It is not affiliated with, endorsed by, or sponsored by Sony
Group Corporation. "Sony", "WH-1000XM5" and related names are trademarks of their respective
owners and are used here only to describe compatibility. The software is provided as-is, with
no warranty. See [LICENSE](LICENSE).

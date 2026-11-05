# Sony headphones protocol notes

These notes cover the subset of Sony's headphone control protocol (often called "MDR") that
sbtfix uses. The v2 details were verified against a WH-1000XM5 on firmware 2.4.1. The v1
details come from Gadgetbridge and haven't been checked on a Mac yet. Corrections and additions
are welcome.

Credit: most of this was first worked out by the
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) project.

## Transport

Bluetooth Classic **RFCOMM**. The channel number is found with an SDP lookup for one of these
service UUIDs:

| UUID | Used by |
|------|---------|
| `956C7B26-D49A-4BA8-B03F-B17D393CB6E2` | "v2" devices (WH-1000XM5 and newer) |
| `96CC203E-5068-46AD-B32D-E316F5E069BA` | "v1" devices (WH-1000XM3/XM4, …) |

The channel can be opened while the headphones are also connected for audio (A2DP/HFP).

## Framing

```
3E | type | seq | length (4 bytes, big-endian) | payload … | checksum | 3C
```

- **type**: `01` = ACK, `0C` = command/data, `0E` = secondary command/data
- **seq**: 0 or 1 (see *Flow control*)
- **checksum**: the low byte of the sum of all bytes from `type` to the end of the payload
- **Escaping**: between the `3E` and `3C` markers, any `3C`, `3D` or `3E` byte (including the
  checksum) is sent as `3D` followed by `byte & 0xEF`:
  `3C → 3D 2C`, `3D → 3D 2D`, `3E → 3D 2E`.

Example: the init request, with payload `00 00` and seq 0:

```
3E 0C 00 00 00 00 02 00 00 0E 3C
```

## Flow control

- Only **one command may be in flight** at a time.
- The host sends a command with its current `seq`. The headphones reply with an ACK frame
  (type `01`, empty payload). The host then **adopts the ACK's seq** for its next command.
- The headphones also send their own commands: replies and unsolicited notifications. The host
  must ACK each of these with `seq = 1 − received_seq`.
- If no ACK arrives, sbtfix waits 1.5 s and then moves on to the next command.

## Payloads

The first payload byte is the message code. For most features, codes come in groups of four:
`GET`, `RET` (reply to a GET), `SET`, `NOTIFY` (the value changed on the device).

### Init

| Direction | Payload |
|-----------|---------|
| → | `00 00` |
| ← | `01 …` (protocol info, e.g. `01 00 03 00 20 16 00 00`) |

Send this first after opening the channel. **The length of the reply tells you the protocol
generation:** 4 bytes means v1 (e.g. `01 00 40 10` from a WH-1000XM3), and 8 bytes means v2.
Everything below is v2 unless it's marked v1.

### Ambient sound / noise cancelling (`66`–`69`)

GET: `66 <type>`, where `<type>` is `15` or `17`. Firmware differs in which one it answers.
The XM5 on firmware 2.4.1 answers only `17`. sbtfix asks with both and then uses the
answered type for SET.

SET / RET / NOTIFY (7 bytes):

```
68 <type> <changed> <on> <mode> <voice> <level>
```

| Byte | Meaning |
|------|---------|
| `changed` | `01` for a final value. The Sony app reportedly sends `00` while a slider is still being dragged. |
| `on` | `00` = everything off, `01` = NC or ambient on |
| `mode` | `00` = noise cancelling, `01` = ambient sound |
| `voice` | Focus on Voice: `00` off, `01` on |
| `level` | Ambient level, `00`–`14` (0–20) |

Some models that support wind-noise reduction send an 8-byte variant. It has an extra byte
before `voice`: `02` = normal, `03`/`05` = wind reduction.

Examples:

```
68 17 01 01 00 00 14   noise cancelling
68 17 01 01 01 00 14   ambient sound, level 20
68 17 01 01 01 01 0A   ambient sound, level 10, focus on voice
68 17 01 00 00 00 14   off
```

### Battery (`22`–`25`, v2)

| Direction | Payload |
|-----------|---------|
| → GET | `22 <kind>`. `00` = single, `09` = left/right (e.g. WF-1000XM5), `01` = left/right on some models (e.g. WF-C700N), `0A` = case |
| ← RET/NOTIFY | Single/case: `23 <kind> <level%> <charging>` (`25 …` for NOTIFY). Left/right: `23 <kind> <L%> <Lchg> <R%> <Rchg>`. A level of 0 means that earbud isn't connected. |

### Speak-to-Chat on/off (`F6`–`F9`, sub-code `0C`)

| Direction | Payload |
|-----------|---------|
| → GET | `F6 0C` |
| → SET | `F8 0C <off> 01`. **Inverted:** `00` = enabled, `01` = disabled. |
| ← RET/NOTIFY | `F7 0C <off> 01` / `F9 …` |

After an enable, the headphones also send `F5 0C 00 00`. What it means is unknown.

## v1 differences

These apply when the init reply is 4 bytes long. Framing and flow control are the same.

### Ambient sound / noise cancelling (`66`–`69`, v1)

GET: `66 02`. SET / RET / NOTIFY (8 bytes):

```
68 02 <on> <wind-capable> <mode> 01 <voice> <level>
```

| Byte | Meaning |
|------|---------|
| `on` | `00` off; SET uses `11` for on, and replies report `01` |
| `wind-capable` | `00` = the model has only NC and ambient, `02` = it also has wind reduction |
| `mode` | Without wind: `00` ambient, `01` NC. With wind: `00` ambient, `01` wind reduction, `02` NC |
| `level` | Ambient level, 0–20; reported as `00` in NC and wind modes |

### Battery (`10`–`13`, v1)

GET `10 <kind>` (`00` single, `01` left/right, `02` case). Replies are `11`/`13` with the same
layout as v2.

### Speak-to-Chat (v1)

| Direction | Payload |
|-----------|---------|
| → GET | `F6 05` |
| → SET | `F8 05 01 <on>` (`01` = enabled, **not** inverted) |
| ← RET/NOTIFY | `F7 05 01 <on>` / `F9 …`. A form with `02` as the third byte is also sent after a SET; it carries no value. |

### Equalizer (`56`–`59`, v1)

| Direction | Payload |
|-----------|---------|
| → GET | `56 01` |
| → SET preset | `58 01 <preset> 00` |
| ← RET/NOTIFY | `57 01 <preset> 06 <clear bass> <400 Hz> <1 kHz> <2.5 kHz> <6.3 kHz> <16 kHz>` / `59 …` |

Each value is a step from -10 to +10, sent with 10 added. Presets on a WH-1000XM4 (fw 2.5.0): `00` Off, `10` Bright,
`11` Excited, `12` Mellow, `13` Relaxed, `14` Vocal, `15` Treble Boost, `16` Bass Boost, `17` Speech, `A0` Manual,
`A1` Custom 1, `A2` Custom 2. The headphones keep the preset across reconnects. Newer models use other ids, so the
app only handles the equalizer on v1.

## Seen but not yet decoded

| Payload | Observed when |
|---------|---------------|
| `17 00 02 00` | Sent when a WH-1000XM4 switches between equalizer Off and a preset, not between presets |
| `A5 01 00 01 00` / `A5 01 00 02 00` | Playback appears to resume or pause (for example when Speak-to-Chat triggers) |
| `A9 …` | Sent frequently during playback |

Pull requests that decode these are welcome.

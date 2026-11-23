# MCHOSE V9 Turbo+ USB/HID protocol

Reverse engineered from the official M HUB app (its device logic is published as a web bundle) and verified on real hardware over macOS IOHIDManager.
Only read queries and reversible writes were verified.

## Device
- USB VID `0x3837`, PID `0x600A`, vendor string "C-Media Electronics Inc", product "MCHOSE V9 Turbo+".
- Composite device: USB Audio Class (stereo output, mono mic) plus one HID interface with vendor usage pages.

## HID report descriptor (decoded)
| Usage page | Report ID | Content |
|---|---|---|
| `0xFF21` | `0xED` | 1 byte in, 1 byte out, 15 byte feature |
| `0xFF22` | `0xAA` | 63 byte feature |
| Consumer `0x0C` | `0x06` | media and volume keys (input) |
| Telephony `0x0B` | `0x07` | hook switch and mute (input), LEDs (output) |
| `0xFF90` | `0x55` | 63 byte input and 63 byte output: **settings channel used by this app** |
| `0xFF82` | `0x41` | 63 byte input and 63 byte output (not used) |

## Settings channel (report ID `0x55`, payload 63 bytes, zero padded)
Send with an Output report. Replies and unsolicited updates arrive as Input report `0x55`.
On macOS the buffer passed to `IOHIDDeviceSetReport` and received by the input callback includes the report ID as byte 0.
Payload below excludes the report ID.

| Feature | Request | Response | Status |
|---|---|---|---|
| Battery | `65 01` | `65 <percent> <status>`; status 2 discharging, 3 charging, 4 full, 26 asleep | verified |
| Read sound mode | `11` | `11 <mode>`; 0 Game 1, 1 Game 2, 2 Music | verified |
| Set sound mode | `21 01 <mode>` | notification `11 <mode>` | verified (changed and restored) |
| Read auto shutdown | `22 02` | `22 02 <v>`; v 1 = 15 min, 4 = 30 min, 0 = 45 min | verified |
| Set auto shutdown | `22 00 <v>` | none | verified (changed and restored) |
| Read prompt volume | `22 04` | `22 04 <v>`, v 1 to 16 | verified |
| Set prompt volume | `22 03 <v>` | none, read back to confirm | verified (changed and restored) |
| Factory reset | `22 01` | none | **not sent, never test casually** |
| Firmware version | Feature report `0xAA`, payload `01 <target>` (0 headset, 1 receiver), wait about 600 ms, then get feature `0xAA`; bytes 2..5 are version digits | | not tested |

Firmware update (OTA) commands exist in the vendor app and are deliberately not implemented here. A bad write can brick the device.

## What is not in the protocol
The 10-band EQ, Xear virtual 7.1 and the other effects of the Windows app (virtual bass, voice clarity, magic voice, adaptive volume) are **Windows audio driver effects** (C-Media APO, controlled through a driver property interface), not headset features.
The "sound mode" above (Game 1, Game 2, Music) is the only on-device sound setting exposed for this model.
That is why this project implements EQ and virtual surround in software on the Mac.

## How to explore it yourself
`tools/hidprobe.swift` opens the device and sends hex payloads given as arguments, printing every input report:

```sh
swiftc -O tools/hidprobe.swift -o tools/hidprobe
tools/hidprobe "65 01" "11" "22 04"
```
`tools/decode_hid.py` decodes a HID report descriptor (hex) from `ioreg -c IOHIDDevice -l`.

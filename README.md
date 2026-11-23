# MchoseHub for macOS

An unofficial menu bar app for the **MCHOSE V9 Turbo+** headset on macOS.
MCHOSE only ships its M HUB software for Windows, so on a Mac you could not change the sound mode, check the battery, or use an equalizer.
This project fills that gap.

> Not affiliated with, endorsed by, or supported by MCHOSE or C-Media. Use at your own risk.

## Features
**Headset settings (over USB HID)**
- Battery level and charging state in the menu bar
- Sound mode: Game 1, Game 2, Music
- Auto shutdown: 15, 30 or 45 minutes
- Voice prompt volume

**Audio processing (software, runs on your Mac)**
- 10-band equalizer with the 15 game and 11 music presets from the official app, plus manual sliders
- Interaction-compensated EQ (each band hits its slider value), automatic preamp to prevent clipping, lookahead limiter at -1 dBFS
- Virtual 7.1 surround for headphones, rendered with measured HRTFs (MIT KEMAR)
- No kernel extension and no audio driver to install

## Requirements
- macOS 14.2 or later (needs Core Audio process taps). Developed and tested on macOS 26, Apple Silicon.
- Xcode command line tools (`xcode-select --install`) to build.
- The headset connected over USB (the 2.4 GHz dongle or a cable).

## Build and run
```sh
git clone https://github.com/jonbertoldi/mchose-hub-mac.git
cd mchose-hub-mac
app/build.sh
open app/MchoseHub.app
```
The build ad-hoc signs the app. macOS may ask for permission the first time:
- **System Audio Recording** is required for the EQ and surround (the app captures system audio, processes it, and plays it to the headset).
- **Microphone** may be requested because the headset is one USB audio device with input and output.

A headphone icon with the battery percentage appears in the menu bar.
If you use several displays, the icon appears on each display's menu bar.
Open **Equalizer...** from the menu for the EQ and 7.1 controls.

## Usage tips
- Turn the headset volume down the first time you enable processing.
- The EQ and 7.1 only run while the **EQ / 7.1** switch is on. Turning it off restores normal macOS audio immediately.
- Strong presets (for example Treble) lower the overall level through the automatic preamp. Raise the headset volume if needed.
- Settings are saved between launches.

## How it works
- **HID control**: the headset exposes a vendor HID channel (report ID `0x55`). The protocol is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **EQ and 7.1**: on Windows these are driver effects, not headset features, so they are reimplemented here.
  The app creates a Core Audio process tap of system audio (excluding itself, original path muted while running) and a private aggregate device with the headset.
  The DSP in `app/DSP.swift` applies a 10-band EQ, the virtual 7.1 mix, and a limiter before the audio reaches the headset.
- **Virtual 7.1**: macOS only gives the app a stereo mix, so this is a stereo to virtual 7.1 upmix (like the Windows effect), not discrete game channels.
  Six virtual speakers (+-30, +-90, +-135 degrees) are convolved with KEMAR HRIRs, with decorrelated rear channels and light early reflections.

## Limitations
- Only the V9 Turbo+ (USB `3837:600A`) is known to work. Other MCHOSE headsets may use similar protocols but are untested.
- The original app's exact EQ band frequencies are unknown. ISO centres (31 Hz to 16 kHz, Q 1.41) are used, so presets may sound slightly different.
- The 7.1 is subjective and tuned by ear. It is not a measured room or your own HRTF.
- Firmware update, factory reset and lighting are intentionally not implemented.
- No notarized release yet: you build it yourself.

## Development
```sh
tests/run.sh         # offline DSP tests (EQ accuracy, limiter, surround levels), no audio device needed
app/build.sh         # build app/MchoseHub.app
swiftc -O tools/hidprobe.swift -o tools/hidprobe && tools/hidprobe "65 01"   # send raw HID payloads (see docs/PROTOCOL.md)
```
Layout:
- `app/main.swift` menu bar app and HID controller
- `app/Processor.swift` Core Audio tap and aggregate device pipeline
- `app/DSP.swift` EQ, virtual 7.1, limiter
- `app/EQView.swift` equalizer window
- `docs/PROTOCOL.md` reverse engineered protocol

## Contributing
Contributions are very welcome, especially:
- Support for other MCHOSE headsets and speakers (capture their HID traffic and add to `docs/PROTOCOL.md`)
- Verifying the firmware version read and other commands
- Better HRTF data (for example SADIE II) or a light reverb for the 7.1
- True-peak limiting, parameter smoothing, and performance work
- A proper Xcode project, signed and notarized releases, a launch-at-login option
- Testing on other macOS versions and hardware

Please run `tests/run.sh` before opening a pull request, and say which headset and macOS version you tested on.
Never test factory reset or firmware (OTA) commands without a way to recover the device.

## Credits and licenses
- Code: MIT, see [LICENSE](LICENSE).
- HRTF data from the MIT KEMAR measurements, see [THIRD_PARTY.md](THIRD_PARTY.md).

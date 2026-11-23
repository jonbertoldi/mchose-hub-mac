#!/bin/sh
# Offline DSP tests (no audio device needed).
set -e
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/dsptest"
swiftc -O app/DSP.swift tests/main.swift -o "$BIN"
MCHOSE_HRIR="$PWD/app/hrir48.bin" "$BIN"

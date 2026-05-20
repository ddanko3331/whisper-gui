#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o whisper-gui-native WhisperGUI.swift -framework AppKit
echo "Built: $(pwd)/whisper-gui-native"

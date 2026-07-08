#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -parse-as-library -O -o whisper-gui-native WhisperGUI.swift -framework AppKit -framework SwiftUI
echo "Built: $(pwd)/whisper-gui-native"

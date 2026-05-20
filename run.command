#!/bin/bash
cd "$(dirname "$0")" || exit 1

if [[ ! -x ./whisper-gui-native ]]; then
  echo "Building native app (first run)…"
  ./build.sh
fi

exec ./whisper-gui-native

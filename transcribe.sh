#!/bin/bash
# Terminal fallback — always works, no GUI needed.
set -euo pipefail

CLI="/opt/homebrew/bin/whisper-cli"
MODEL="${WHISPER_MODEL:-$HOME/whisper-medium.bin}"
AUDIO="${1:-}"

if [[ -z "$AUDIO" ]]; then
  AUDIO=$(osascript -e 'POSIX path of (choose file with prompt "Pick audio to transcribe")' 2>/dev/null || true)
fi
if [[ -z "$AUDIO" || ! -f "$AUDIO" ]]; then
  echo "No audio file." >&2
  exit 1
fi

STEM="${AUDIO%.*}"
echo "Transcribing (CPU)…"
"$CLI" -ng -m "$MODEL" -f "$AUDIO" -t 4 -l auto -pp -otxt -nt -of "$STEM" "$AUDIO"

echo ""
echo "=== Transcript ==="
cat "${STEM}.txt"
echo ""
echo "Saved: ${STEM}.txt"
open -R "${STEM}.txt"

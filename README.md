# Whisper GUI

Native macOS app for [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (`whisper-cli` from Homebrew).

> **Note:** `/usr/bin/python3` + Tk is broken on many recent macOS versions (instant crash). Use the **native app** below, not `whisper_gui.py`.

## Requirements

- `whisper-cli` — `brew install whisper-cpp`
- Model `.bin` — e.g. `~/whisper-medium.bin`

## Run (native — recommended)

```bash
cd ~/whisper-gui && ./run.command
```

Or:

```bash
cd ~/whisper-gui
./build.sh          # first time only
./whisper-gui-native
```

## Terminal fallback (no GUI)

```bash
~/whisper-gui/transcribe.sh
# or with a file:
~/whisper-gui/transcribe.sh ~/input_ready.wav
```

## Usage

**Main** tab — drop audio, transcribe, view log and transcript.

**Advanced** tab — scrollable form with **Conversion** and **Transcription** sections (ffmpeg + whisper-cli settings).

Settings save to `~/Library/Application Support/whisper-gui/settings.json` (auto-saved when you transcribe, or click **Save settings**).

1. **Drop** any audio or video file on the drop zone (or use **Choose…**).
2. Non-native formats (mp4, m4a, mov, mkv, …) are converted to `*_whisper.wav` via **ffmpeg** (16 kHz mono).
3. Leave **Use GPU** off (CPU is reliable; GPU often crashes with large models).
4. Click **Transcribe** — log on top, transcript below when done.
5. Output `.txt` is saved next to the audio file.

Requires `brew install ffmpeg` for conversion.

## Voice Memos

Recordings live as **`.m4a`** files (not visible in normal Finder browsing):

```
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
```

**In the app:** click **Voice Memos** to open that folder in the file picker. `.m4a` / `.qta` are converted via ffmpeg to a writable folder:

`~/Library/Application Support/whisper-gui/converted/`

(macOS does not allow saving new files inside the Voice Memos Recordings folder.)

**Other ways:**

1. **Drag** a memo from the Voice Memos app into the drop zone.
2. **Share → Save** from Voice Memos, then drop the saved file.
3. **Finder → Go → Go to Folder** (⇧⌘G), paste the path above, copy a `.m4a` out.

If the folder is empty, memos may still be syncing via iCloud — open Voice Memos once, or export via Share.

Medium model on CPU can take several minutes.

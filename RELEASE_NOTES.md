# Release Notes & Version History

This document logs the version history, feature additions, and technical specifications of the **Whisper GUI** macOS native application.

---

## [v1.3.0] — SwiftUI Native Migration
*Released: July 2026*

This version introduces a complete architectural rewrite of the macOS application frontend, migrating from legacy imperative AppKit to modern, declarative SwiftUI. This migration reduced layout boilerplate and resource footprints, improving performance and modernizing the design.

### Added
*   **Sidebar Navigation (`NavigationSplitView`)**: Adopted modern macOS HIG guidelines, replacing top tabs with a collapsible vertical sidebar containing **Transcribe**, **Browser**, and **Advanced Settings** sections.
*   **Tag Flow Chips Layout**: Dynamic, wrap-around bubble chips for selecting meeting tags. Integrates directly with your Obsidian vault to import existing vault tags.
*   **Reactive State bindings**: Unified all application states into an `@ObservedObject` (`AppModel`), making UI updates for background transcription and logs completely reactive.
*   **Rich Text Highlight Bridge (`NSViewRepresentable`)**: Wrapped `NSTextView` in SwiftUI to support paragraph background coloring for speaker tracks and dynamic timestamp seeking during audio playback.
*   **Contacts Combo Box Bridge**: Wrapped Cocoa's `NSComboBox` inside SwiftUI to preserve native autocompleting list queries for macOS Contacts.

### Technical Changes
*   Updated `build.sh` to compile with the `-parse-as-library` and `-framework SwiftUI` compiler flags.
*   Changed minimum system target version (`LSMinimumSystemVersion`) to **macOS 13.0 (Ventura)** to support SwiftUI split view containers.

---

## [v1.2.0] — Contacts Integration & Speaker Training
*Released: June 2026*

This release integrates the macOS Address Book (Contacts) into the application to allow mapping biometric voice prints to physical contact cards and introduces a custom speaker voice training mechanism.

### Added
*   **Contacts Autocomplete**: Searchable text dropdowns listing macOS Contact names when renaming speakers inside transcripts.
*   **Voice Profiling Training Mode**: A new modal dialog ("Register Voice...") allowing you to register custom speaker signatures directly to contact cards by extracting embeddings from small `.wav` samples.
*   **AppleScript Fallback**: Silent AppleScript query fallback to retrieve contact lists on systems with restricted AppKit permissions.
*   **Signature Separation**: Dynamic signature separation between **Goertzel** (24-band spectral signatures) and **Sherpa-ONNX** (512-band neural embeddings) to prevent math dimension mismatches during verification.

### Security & Packaging
*   Added `NSContactsUsageDescription` inside `package_app.sh` plist generator. This describes contacts usage to the OS, preventing instant sandboxed crashes when checking address book records.

---

## [v1.1.0] — Speaker Diarization & Obsidian Integration
*Released: May 2026*

This update adds advanced speaker diarization, visual speaker identity mapping in transcripts, and automated notes sync to Obsidian.

### Added
*   **Speaker Diarization Engine**: Integration of `speaker_engine.py` executing Goertzel spectral math and Sherpa-ONNX CAM++ neural models to segment and characterize active speakers.
*   **Obsidian Synchronization**: Automated formatting and synchronization of transcripts as Markdown notes into your local Obsidian Vault directory, supporting tag arrays and frontmatter metadata.
*   **Timeline Color Coding**: Dynamic paragraph text coloring based on the unique hash of the speaker's name.
*   **Interactive Audio Player**: Combined playback toolbar with track progress timeline, seeking, and automated scrolling highlight matching active lines.

---

## [v1.0.0] — Initial Release
*Released: April 2026*

Initial implementation of the Whisper GUI native macOS wrapper.

### Added
*   Native AppKit window with basic drop zone.
*   Background process piping and execution for `whisper-cli`.
*   Automatic audio downsampling and conversion using `ffmpeg`.
*   Local persistent configuration storage (`settings.json`).

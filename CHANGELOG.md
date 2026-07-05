# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.1] — 2026-07-05

### Added
- **Local transcription**: whisper.cpp `large-v3-turbo` (Metal-accelerated), runs
  automatically after each recording; timestamped Markdown transcript is saved
  next to the audio file. Language auto-detection.
- Per-recording controls: transcribe manually, watch progress, open transcript.
- Automatic Whisper model updates via the `models.json` manifest (checked daily).
- Movable main window with hidden title bar and a pin-on-top toggle.
- Menu bar quick actions: start/stop with timer, open window, open folder, quit.
- Single-instance guard: launching a second copy focuses the running one;
  re-opening the app always shows the window.

### Changed
- Main UI moved from an anchored menu-bar panel to a regular draggable window.
- `whisper-cli` (static arm64 build, Metal embedded) is bundled inside the app —
  the DMG stays fully self-contained.

## [1.0] — 2026-07-05

Initial release.

- System audio + microphone recording into a single `.m4a` (ScreenCaptureKit,
  48 kHz AAC), with a raw two-track fallback so recordings are never lost.
- Menu bar app with recording timer, recent recordings list, output folder
  picker and automatic Google Drive detection.
- DMG installer; ad-hoc signed app bundle with generated icon.
- Minimal CLI variant (`meetrec`).

# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.5] — 2026-07-05

### Added
- **Launch at login**: a checkbox in the window footer registers MeetRec as a
  login item (SMAppService), so recording is always one click away.

### Fixed
- README accuracy pass: button description matched to the actual UI, roadmap
  section removed, architecture notes updated for video recording.

## [1.4] — 2026-07-05

### Added
- **Speaker diarization** (optional toggle): transcripts become a dialog —
  «Спикер 1 [00:12]: …» — powered by [FluidAudio](https://github.com/FluidInference/FluidAudio)
  CoreML models (pyannote-based), fully on-device. Models (~30 MB) download
  automatically on first use. If diarization fails, the plain transcript is
  saved unchanged.

### Changed
- Build migrated from a plain `swiftc` invocation to Swift Package Manager
  (`Package.swift`); `./build.sh` works as before.

## [1.3] — 2026-07-05

### Added
- **Screen video recording** (optional toggle): captures the main display at
  30 fps (HEVC, hardware-encoded on the fly, up to 2560 px wide) alongside
  audio. Produces two files: the usual `.m4a` for transcription plus an `.mp4`
  with the screen video and mixed audio — finalized in seconds via remux,
  no re-encoding.
- Live recording size indicator under the timer while video is enabled.
- Film button next to recordings that have a video file.

## [1.2.1] — 2026-07-05

### Changed
- MeetRec now appears in the Dock and Cmd+Tab and can be kept in the Dock;
  the menu bar icon with the recording timer remains.
- Quitting via Cmd+Q or the Dock during a recording now stops and saves the
  recording before the app exits.

## [1.2] — 2026-07-05

### Added
- **Google Calendar integration** (OAuth 2.0 PKCE with loopback redirect, tokens
  in the macOS Keychain, read-only scope):
  - recordings are automatically named after the current meeting;
  - transcript header includes meeting title, time and attendees;
  - the next meeting is shown in the main window;
  - a "Meeting started" notification offers one-click recording.
- OAuth client credentials are read from a local `google_oauth.json`
  (never bundled or committed); `google_oauth.example.json` documents the format.

### Notes
- Google verification is in progress; until it completes, each user needs their
  own OAuth client for the calendar features (see README).

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

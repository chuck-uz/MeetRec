# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.12] — 2026-07-06

### Added
- **Error logs**: MeetRec now writes a log to `~/Library/Logs/MeetRec/MeetRec.log`
  (recording, transcription, summary, model-load events and all errors). New
  "Показать логи…" menu item and a "Показать логи" button on error cards reveal
  the file in Finder so it can be shared for diagnosis.

### Changed
- Error messages are shown in full (multi-line, selectable) instead of being
  truncated.
- The local model load now waits longer (up to 180 s) and captures the model
  server's stderr, so failures report the real cause (e.g. out of memory).

## [1.11] — 2026-07-06

### Added
- **Check for updates**: a "Проверить обновления…" menu item queries the latest
  GitHub release and offers to open the release page if a newer version exists.
  A daily background check surfaces an "обновить" badge in the window header.
- **App version** shown next to the "MeetRec" title in the window.

## [1.10] — 2026-07-06

### Added
- **"Мои встречи" — unified window**: a wide split-view window with all recordings
  in the sidebar and, on the right, an AI chat for the selected recording plus
  quick actions (open audio/video, transcript, summary). The global archive
  search now lives in the same window (top of the sidebar). Replaces the separate
  chat and search windows.

## [1.9] — 2026-07-06

### Added
- **Pause / resume recording**: a pause button next to the record button (and a
  menu bar item) suspends recording; the paused interval is cut out of the final
  file so the timeline stays seamless — no silence gap. Works for audio and
  screen video (tracks stay in sync via sample-timestamp offsetting). The timer
  freezes while paused and shows active recording time.

## [1.8] — 2026-07-06

### Added
- **Automatic meeting summary** (optional toggle, Macs with 16+ GB): after
  transcription the local LLM writes a structured summary — «Кратко / Решения /
  Задачи (action items)» — saved as a companion `… — итоги.md` next to the
  recording. Can also be generated on demand per recording. Summaries are kept
  out of the archive search index. Fully on-device.

## [1.7] — 2026-07-06

### Added
- **Global archive search / local RAG** (Macs with 16+ GB unified memory): ask a
  question across *all* past meetings and get an answer with cited sources.
  Fully on-device — transcripts are chunked, embedded with **bge-m3** (llama.cpp,
  Metal), and stored in a local SQLite index (FTS5 keyword + vector search fused
  via Reciprocal Rank Fusion). The retrieved fragments are answered by the same
  local Qwen 2.5 model. Nothing leaves the Mac.
- New meetings are indexed automatically after transcription; existing transcripts
  are indexed on first opening the search window.
- Embedding model (~0.4 GB) downloads automatically on first use.

## [1.6] — 2026-07-06

### Added
- **Local AI chat per meeting** (Macs with 16+ GB unified memory): a chat
  window over any transcript — summary, action items, decisions, follow-up
  email templates or free-form questions. Powered by a bundled static
  `llama-server` (llama.cpp, Metal) running Qwen 2.5 7B Instruct (Q4_K_M,
  ~4.7 GB, downloaded automatically on first use). Fully offline; the model
  is unloaded after 5 minutes of inactivity to free memory.
- The LLM can be swapped remotely via the `models.json` manifest (`llm` key).

### Changed
- Model downloads unified into a shared downloader (Whisper + LLM).

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

<div align="center">

<img src="docs/icon.png" width="128" alt="MeetRec icon">

# MeetRec

**Record your meetings on macOS — system audio and microphone in one file, with fully local transcription.**

[![Release](https://img.shields.io/github/v/release/chuck-uz/MeetRec?color=0891B2)](https://github.com/chuck-uz/MeetRec/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B-blue)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-success)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

[Русская версия](README.md)

<img src="docs/screenshot.png" width="360" alt="MeetRec main window">

</div>

## Why MeetRec

Every meeting tool records only itself. MeetRec records **any** meeting — Zoom, Google Meet, Teams, a phone call in your browser — because it captures the Mac's system audio together with your microphone and mixes them into a single `.m4a`. When the meeting ends, a text transcript with timestamps appears next to the recording. Everything happens **on your Mac**: no servers, no subscriptions, nothing leaves your machine.

## Features

- **One-click recording** — a big round button in a compact window (turns red and pulses while recording), or start straight from the menu bar; a live timer sits next to the clock.
- **System audio + microphone** captured simultaneously via ScreenCaptureKit and mixed into one stereo AAC file (48 kHz).
- **Local transcription** — [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the `large-v3-turbo` model, Metal-accelerated. An hour of audio takes ~4–6 minutes in the background. Language is auto-detected (Russian, English, and 90+ others).
- **Timestamped Markdown transcripts** (`[03:12] …`) saved next to each recording — ready to paste into your favorite LLM.
- **Speaker diarization (optional)** — transcripts as a dialog, «Спикер 1 / Спикер 2…» ([FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML, fully on-device; ~30 MB models download automatically).
- **Local AI chat per meeting** (Macs with 16+ GB memory) — summaries, action items, decisions, follow-up drafts or free-form questions over any transcript. Qwen 2.5 7B via bundled [llama.cpp](https://github.com/ggml-org/llama.cpp) (Metal); the ~4.7 GB model downloads on first use and unloads after 5 idle minutes. Answers never leave your Mac.
- **Global archive search (local RAG)** (Macs with 16+ GB memory) — ask one question across *all* meetings and get an answer with cited sources. Transcripts are chunked, embedded with [bge-m3](https://huggingface.co/BAAI/bge-m3) and stored in a local SQLite index (FTS5 keyword + vector search, fused via RRF); the same local Qwen writes the answer. Nothing leaves your Mac.
- **Self-updating model** — the app checks [`models.json`](models.json) daily and downloads the newer recommended Whisper model automatically.
- **Google Drive aware** — if Google Drive for desktop is installed, recordings go to *My Drive → Записи встреч* and sync to the cloud automatically.
- **Google Calendar integration** — recordings are named after the current meeting, attendees go into the transcript header, and a "Meeting started" notification offers one-click recording. See [setup below](#google-calendar-optional).
- **Screen video recording (optional)** — a toggle captures the whole screen at 30 fps (HEVC, hardware-encoded, ~0.7–1.5 GB/hour) alongside audio. An `.mp4` with the mixed audio appears next to the `.m4a`; file size is shown live while recording.
- **Stays out of your way** — movable window with a pin-on-top toggle, quick actions in the menu bar, launch-at-login checkbox.

## Installation

1. Download `MeetRec.dmg` from the [latest release](https://github.com/chuck-uz/MeetRec/releases/latest).
2. Open it and drag **MeetRec** into **Applications**.
3. First launch: right-click → **Open** (the app is ad-hoc signed, so Gatekeeper asks once).
4. On the first recording, grant two permissions in *System Settings → Privacy & Security*:
   - **Screen & System Audio Recording** — to capture meeting audio;
   - **Microphone** — to capture your voice.

The Whisper model (~1.6 GB) is downloaded automatically before the first transcription, with progress shown in the app.

## Google Calendar (optional)

With the calendar connected, MeetRec:

- names recordings after the current meeting — "Platform sync — 2026-07-05 15.00.m4a" instead of a bare date;
- adds the meeting title, time and attendees to the transcript header;
- shows your next meeting in the window;
- sends a "Meeting started" notification with a one-click **Record** button.

Access is read-only (`calendar.readonly`); tokens are stored in the macOS Keychain and never leave your machine.

> **⏳ Status: the app is going through Google's verification process.** Until it
> completes, OAuth credentials are not bundled — each user needs their own (free)
> OAuth client. It takes ~10 minutes:
>
> 1. Create a project in the [Google Cloud Console](https://console.cloud.google.com) and enable the **Google Calendar API**.
> 2. Configure the OAuth consent screen (External) and publish it **In production**.
> 3. Create an OAuth client of type **Desktop app**.
> 4. Copy [google_oauth.example.json](google_oauth.example.json) to
>    `~/Library/Application Support/MeetRec/google_oauth.json` and fill in your `client_id` and `client_secret`.
> 5. Click **«Подключить»** in the calendar card in MeetRec; on the
>    "Google hasn't verified this app" warning choose *Advanced → Continue* (it's your own app).
>
> Once verification is complete, the calendar will work out of the box.

## Requirements

- macOS 15 Sequoia or newer
- Apple Silicon (built and tested on M-series)

## Usage

| Action | How |
|---|---|
| Start / stop recording | Click the big button, or the menu bar icon → *Начать запись* |
| Watch recording time | Timer appears in the menu bar next to the icon |
| Open a recording or transcript | Click it in the *Последние записи* list |
| Transcribe an older recording | Click the ⊕-text icon in its row |
| Label speakers in transcripts | «Диаризация» toggle |
| Chat with AI about a meeting | 💬 icon in a transcribed recording's row |
| Keep window above Zoom | Pin icon in the window header |
| Change output folder | *Изменить* in the folder card |
| Record screen video | «Видео экрана» toggle before starting |
| Open a recording's video | Film icon in the recording row |

## How it works

```
ScreenCaptureKit ──► system audio ─┐
                                   ├─► AVAssetWriter (.mov, 2 tracks) ─► mixdown ─► .m4a
AVFoundation ──────► microphone  ──┘                                                 │
                                                                                     ▼
                                              whisper.cpp (Metal) ─► transcript .md with timestamps
```

- The recorder writes the sources as separate tracks (plus a video track when enabled) and mixes them down on stop; if the mixdown ever fails, the raw multi-track file is kept, so a recording is never lost.
- `whisper-cli` is statically compiled (Metal embedded, system frameworks only) and bundled inside the app — the DMG is fully self-contained.
- Transcription runs `afconvert` → `whisper-cli` → JSON → Markdown, entirely offline.

## Building from source

```sh
git clone https://github.com/chuck-uz/MeetRec.git
cd MeetRec
./build.sh        # produces build/MeetRec.app and dist/MeetRec.dmg
```

Requires Xcode Command Line Tools. The bundled `app/bin/whisper-cli` is a static universal-free arm64 build of whisper.cpp (`cmake -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`); rebuild it the same way if you want to bump whisper.cpp.

A minimal CLI variant also lives in the repo: `swiftc -O -parse-as-library MeetRec.swift -o meetrec && ./meetrec`.

## Privacy

MeetRec only goes online to fetch models (Whisper and diarization — from Hugging Face, once) and the recommended-models manifest `models.json` in this repository; with Google Calendar connected, it also calls the Calendar API (read-only). Audio and transcripts never leave your Mac. Always make sure recording meetings is legal in your jurisdiction and that participants are informed.

## License

[MIT](LICENSE)

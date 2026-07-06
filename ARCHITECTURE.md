# MeetRec — Architecture

Technical documentation for developers. It explains how MeetRec is structured,
how each subsystem works, and the design decisions behind it. For product/usage
docs see [README.md](README.md); for the dev workflow see [CONTRIBUTING.md](CONTRIBUTING.md).

- **Platform:** macOS 15+ (Apple Silicon), native Swift / SwiftUI.
- **Size:** ~4.4k lines of Swift across 18 source files, one third-party SPM
  dependency, three bundled native binaries/models.
- **Philosophy:** *local-first*. Every feature — recording, transcription,
  diarization, LLM chat, semantic search, summarization — runs on the user's Mac.
  The only network calls are one-time model downloads and an update/manifest check.

---

## 1. High-level pipeline

```
                          ┌──────────────────────── AppState (@MainActor store) ───────────────────────┐
                          │  owns all UI state, coordinates every subsystem, routes errors to the log  │
                          └───────────────────────────────────────────────────────────────────────────┘
                                │              │               │                │              │
        ┌───────────────────────┘              │               │                │              └───────────────┐
        ▼                                       ▼               ▼                ▼                              ▼
  RecorderEngine                          Transcriber     DiarizationService  Summarizer                 GoogleCalendar
  ScreenCaptureKit                        whisper-cli     FluidAudio (CoreML) LLMRuntime                 Calendar API
  + AVAssetWriter                         + Silero VAD    "who spoke"         "Кратко/Решения/Задачи"    (read-only)
        │                                       │                                                              ▲
        ▼                                       ▼                                                              │
   .m4a  (+ .mp4)  ───────────────────►  transcript .md  ──────────────────────────────────────────►  GoogleAuth (OAuth PKCE)
        │                                       │
        │                                       ├──►  ArchiveIndexer → EmbeddingService (bge-m3) → ArchiveStore (SQLite)
        │                                       │                                                        ▲
        │                                       └──►  ChatView / MeetingsView ──► LLMRuntime (Qwen) ◄─────┘  (RAG retrieval)
        ▼
  ~/Documents/Записи встреч/   (audio, video, transcript, summary — all side by side)
```

The unit of work is a **recording**. Everything downstream (transcript, summary,
search index entry) is a derived artifact stored next to the audio file.

---

## 2. Tech stack

| Concern | Choice | Why |
|---|---|---|
| UI | SwiftUI (`App`, `Window`, `MenuBarExtra`) + a small `NSApplicationDelegate` | Native, menu-bar + windowed, minimal code |
| Capture | ScreenCaptureKit (`SCStream`) + AVFoundation (`AVAssetWriter`) | System audio + mic + screen video in one API |
| Speech-to-text | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `large-v3-turbo`, Metal | Fast, accurate, fully local; bundled static CLI |
| Voice activity detection | Silero VAD (whisper.cpp `--vad`) | Removes Whisper's pause/silence hallucinations |
| Diarization | [FluidAudio](https://github.com/FluidInference/FluidAudio) (pyannote CoreML) | Native Swift, runs on the Neural Engine |
| Local LLM | [llama.cpp](https://github.com/ggml-org/llama.cpp) server, Qwen 2.5 7B (Q4_K_M), Metal | OpenAI-compatible HTTP, streaming, strong Russian |
| Embeddings | bge-m3 via llama.cpp `--embedding` (1024-dim) | Best-in-class multilingual retrieval |
| Vector store | System SQLite (FTS5 + Float32 BLOBs), brute-force cosine via `Accelerate`/vDSP | Zero dependencies; a personal archive is tiny |
| Calendar | Google Calendar REST API, OAuth 2.0 PKCE + loopback | Read-only; tokens in Keychain |
| Build | Swift Package Manager (`swift build -c release`) | Pulls FluidAudio; bundles native binaries via `build.sh` |

Only external SPM dependency: **FluidAudio**. Everything else is Apple frameworks
plus three bundled native artifacts (`whisper-cli`, `llama-server`, the VAD model).

---

## 3. Source layout

All Swift lives in `app/Sources/` (single executable target `MeetRec`).

| File | Lines | Responsibility |
|---|---|---|
| `MeetRecApp.swift` | 172 | `@main` App: window scenes (`main`, `meetings`), `MenuBarExtra`, `AppDelegate` (single-instance, notifications, terminate-while-recording) |
| `AppState.swift` | 729 | **Central `@MainActor ObservableObject`** — all published state, orchestration of every subsystem, error routing to `Log`, LLM model selection/downloads |
| `ContentView.swift` | 750 | Main window UI (record button, feature cards, recent list, footer) + gear entry to the model screen |
| `MeetingsView.swift` | 204 | "Мои встречи" split-view window (sidebar + chat/search detail) |
| `ChatView.swift` | 248 | Per-meeting AI chat (view + `ChatViewModel`) |
| `ModelSettingsView.swift` | 185 | AI-model picker screen — hardware fit badges, per-model download/delete |
| `ArchiveSearchView.swift` | 226 | Global archive search UI (view + `ArchiveSearchModel`) |
| `RecorderEngine.swift` | 318 | Capture → `AVAssetWriter` → mixdown/remux; pause via timestamp offset |
| `Transcriber.swift` | 345 | `whisper-cli` orchestration, VAD, JSON → Markdown (plain or diarized) |
| `DiarizationService.swift` | 68 | FluidAudio wrapper → speaker timeline |
| `Summarizer.swift` | 66 | Transcript → structured summary via `LLMRuntime` |
| `LLMRuntime.swift` | 249 | `actor` managing `llama-server`; streaming + one-shot generation; `Hardware` (RAM, chip) |
| `LLMCatalog.swift` | 106 | LLM catalog (Qwen 3B/7B/14B) + per-model hardware fit and download state |
| `EmbeddingService.swift` | 102 | `actor` managing a second `llama-server` in `--embedding` mode |
| `ArchiveStore.swift` | 286 | `actor` over SQLite: chunks, FTS5, vector search, RRF fusion |
| `ArchiveIndexer.swift` | 175 | Transcript parsing, chunking, indexing orchestration, RAG prompt |
| `GoogleAuth.swift` | 306 | OAuth 2.0 PKCE + loopback HTTP server; Keychain token storage |
| `GoogleCalendar.swift` | 135 | Calendar API client (upcoming events, current/next meeting) |
| `UpdateChecker.swift` | 41 | GitHub Releases version check |
| `Downloader.swift` | 40 | Shared streaming file downloader with progress |
| `Log.swift` | 56 | File logger at `~/Library/Logs/MeetRec/MeetRec.log` |

`MeetRec.swift` at the repo root is a legacy standalone CLI recorder (v1.0), kept
for reference; it is **not** part of the app target.

---

## 4. Runtime & state

- **`AppState`** is the single source of truth. It's `@MainActor`, injected into
  every view via `.environmentObject`, and exposes a static `shared` so
  detached tasks (e.g. the chat models) can check `transcribeProgress` and avoid
  competing for memory with an active transcription.
- **Windows** are declared as SwiftUI `Window` scenes with stable ids
  (`main`, `meetings`) and opened via `openWindow(id:)`. A `WindowBridge`
  singleton lets the `AppDelegate` reopen the main window after it's closed.
- **Menu bar** (`MenuBarExtra`, `.window` style historically, now a menu) shows a
  live recording timer and quick actions.
- **Persistence:** lightweight settings in `UserDefaults` (toggles, chosen
  language, output dir, model manifest overrides, last-check timestamps).
  Everything heavy is a file on disk or a row in SQLite.

### Concurrency model

| Component | Isolation | Notes |
|---|---|---|
| `AppState`, all views/view-models | `@MainActor` | UI thread |
| `LLMRuntime`, `EmbeddingService`, `ArchiveStore` | `actor` | Serialize access to a subprocess / DB |
| `Transcriber` | `final class` (shared) | Subprocess orchestration via async `Process` wrappers |
| `RecorderEngine` sample handling | private serial `DispatchQueue` | All `SCStream` callbacks + pause state are serialized here |

Swift language mode is set to **v5** (`Package.swift`) to keep the pragmatic
`@unchecked Sendable` helper classes (token/stderr buffers) simple.

---

## 5. Subsystems

### 5.1 Recording — `RecorderEngine.swift`

- One `SCStream` delivers three output types: `.audio` (system), `.microphone`,
  `.screen` (video, only when video capture is on).
- An `AVAssetWriter` writes a temp `.mov` with **separate** audio tracks for
  system and mic (plus an HEVC video track when enabled).
- **Pause/resume** works by offsetting timestamps: while paused, samples are
  dropped and the pause boundary recorded; on resume the accumulated pause
  duration is subtracted from every subsequent sample's PTS via
  `CMSampleBufferCreateCopyWithNewTiming`. The pause is thus *cut out* of the
  timeline (no silence gap), and all tracks stay in sync because one global
  offset applies to all of them (same host clock).
- **On stop:** `AVAssetExportSession` mixes the two audio tracks down to a single
  `.m4a`; if video was captured, a second pass-through export remuxes the video
  track + mixed audio into `.mp4` (no re-encode → seconds, not minutes). If any
  step fails, the raw multi-track `.mov` is kept so a recording is never lost.

Output naming: `<meeting title or "Встреча"> — yyyy-MM-dd HH.mm.m4a` (title comes
from the calendar when connected).

### 5.2 Transcription — `Transcriber.swift`

Pipeline: `afconvert` (→ 16 kHz mono WAV) → `whisper-cli` → JSON → Markdown.

- The bundled static `whisper-cli` runs with the model, chosen language
  (`Transcriber.language`, default = system language), flash attention, and
  **always-on VAD** (`--vad --vad-model <bundled Silero>`). VAD is the key to
  transcript quality — it eliminates the repetition hallucinations Whisper
  produces on pauses.
- Output is rendered to Markdown in one of two shapes:
  - **plain** `**[mm:ss]** text` (`renderMarkdown`), or
  - **dialog** `**Спикер N [mm:ss]:** text` (`renderDialog`) when diarization is on.
- Models live in `~/Library/Application Support/MeetRec/models/` and are
  auto-updated from [`models.json`](models.json) (checked daily).

### 5.3 Diarization — `DiarizationService.swift`

Wraps FluidAudio's `DiarizerManager` (pyannote segmentation + embedding CoreML
models, ~30 MB, auto-downloaded). Returns a speaker timeline
(`[SpeakerSegment]`); `Transcriber.renderDialog` assigns each Whisper segment to
the speaker with maximum temporal overlap and groups consecutive turns. Failure
is non-fatal — the plain transcript is written instead.

### 5.4 Local LLM — `LLMRuntime.swift`

- An `actor` that launches the bundled static `llama-server` (llama.cpp, Metal)
  as a child process on `127.0.0.1:<random port>`, serving an OpenAI-compatible
  API. The Qwen 2.5 7B model (~4.7 GB) is downloaded once on first use.
- `generate(turns:onToken:onStatus:)` streams tokens from
  `/v1/chat/completions`; `complete(turns:)` accumulates a full response (used by
  the summarizer).
- The server's **stderr is captured** so load failures report the real cause
  (e.g. out of memory), and it's **shut down after 5 minutes idle** to free RAM.
- Gated by `Hardware.supportsChat` (≥ 16 GB unified memory).
- **Model selection** (`LLMCatalog.swift` + `ModelSettingsView.swift`): the user
  picks among Qwen 2.5 **3B / 7B / 14B** (Q4_K_M) from a gear screen in the main
  window. Each model carries `minRAMGB`/`comfortRAMGB` thresholds; on Apple Silicon
  the only real constraint is unified memory, so `fit(ramGB:)` classifies each as
  *comfortable / tight / insufficient* and the best comfortable one is badged
  **Рекомендуется**. A model can be pre-downloaded (progress) or is fetched lazily
  on first use, and deleted to reclaim disk. An explicit choice sets
  `llmModelUserChosen`, which stops the `models.json` manifest from overriding it.

### 5.5 Summarization — `Summarizer.swift`

After transcription (if enabled) the transcript is sent to `LLMRuntime.complete`
with a system prompt that forces a fixed Markdown shape (`## Кратко / ## Решения
/ ## Задачи`). The result is written to `<name> — итоги.md` next to the
recording. Summary files are recognized by the ` — итоги` suffix and **excluded
from the search index** so derived text doesn't pollute retrieval.

### 5.6 Archive search / RAG — `ArchiveStore`, `ArchiveIndexer`, `EmbeddingService`

- **Indexing:** `ArchiveIndexer` parses a transcript `.md` (regex over
  `**[speaker] [mm:ss]:** text` lines), groups turns into ~1600-char chunks with
  overlap, embeds them with **bge-m3** (via a dedicated `llama-server` in
  `--embedding --pooling cls` mode, 1024-dim), and stores them in SQLite.
  New meetings are indexed automatically after transcription; existing ones on
  first opening the search window.
- **Storage (`ArchiveStore`, an `actor` over system SQLite):** a `chunks` table
  (meeting id, timestamp, speaker, text, normalized embedding as a Float32 BLOB)
  and an FTS5 virtual table (`trigram` tokenizer, works with Russian).
- **Retrieval:** hybrid — vector search (`vDSP_dotpr` cosine over the whole
  index, milliseconds for a personal archive) **fused with** FTS5 keyword search
  via **Reciprocal Rank Fusion**. The top chunks become the context for a Qwen
  answer that cites sources `[1] [2]`.

Rationale: for a personal archive (thousands of chunks) brute-force cosine in
`Accelerate` is milliseconds, so a dedicated vector DB would be over-engineering.
`sqlite-vec` is the escape hatch if an archive ever grows past ~100k chunks.

### 5.7 Google Calendar — `GoogleAuth`, `GoogleCalendar`

- **Auth (`GoogleAuth`):** OAuth 2.0 Authorization Code + **PKCE** with a
  **loopback redirect** — a tiny `NWListener` HTTP server on `127.0.0.1` catches
  the redirect. Tokens are stored in the **macOS Keychain**; the access token is
  refreshed on demand. Client credentials are read from a local
  `google_oauth.json` (never bundled/committed).
- **Client (`GoogleCalendar`):** reads selected calendars, exposes upcoming
  events, current/next meeting. Scope is **read-only** (`calendar.readonly`).
- Used for auto-naming recordings, transcript headers, and the "meeting started"
  notification.

### 5.8 Cross-cutting — updates, logging, downloads

- **`UpdateChecker`** queries the GitHub Releases API and compares versions
  numerically (so `1.10 > 1.9`). A daily background check surfaces an "обновить"
  badge; a menu item runs it manually.
- **`Log`** appends timestamped lines to `~/Library/Logs/MeetRec/MeetRec.log`
  (trimmed to ~256 KB). `AppState.errorMessage` has a `didSet` that logs every
  surfaced error in full, so a shared log always contains the real cause.
- **`Downloader`** streams large files with progress and atomic move-on-complete;
  shared by Whisper/LLM/embedding model downloads.

---

## 6. Data & storage

| What | Where |
|---|---|
| Recordings, transcripts, summaries | `~/Documents/Записи встреч/` (or Google Drive folder, auto-detected; user-configurable) |
| ML models (Whisper, Qwen, bge-m3) | `~/Library/Application Support/MeetRec/models/` |
| Search index | `~/Library/Application Support/MeetRec/archive.sqlite` |
| Google OAuth client config | `~/Library/Application Support/MeetRec/google_oauth.json` (local only) |
| Google tokens | macOS Keychain (`ru.dinya.meetrec.google`) |
| Logs | `~/Library/Logs/MeetRec/MeetRec.log` |
| Settings | `UserDefaults` (toggles, language, output dir, timestamps) |
| Bundled binaries/models | inside `MeetRec.app` (`Contents/MacOS/{whisper-cli,llama-server}`, `Contents/Resources/ggml-silero-*.bin`) |

---

## 7. Build, signing & release

- **Build:** `swift build -c release` (SPM). `./build.sh` assembles the `.app`
  bundle (copies the binary + Info.plist + native binaries + icon), signs it,
  and produces `dist/MeetRec.dmg`.
- **Signing is critical:** the app is signed with a stable self-signed
  certificate **"MeetRec Dev"**. A stable *designated requirement*
  (`identifier "ru.dinya.meetrec" and certificate leaf = H"…"`) is required so
  macOS keeps Screen Recording / Microphone permissions across rebuilds. Ad-hoc
  signing loses those permissions on every rebuild and is only a fallback (with a
  warning). See the signing block in `build.sh`.
- **Install:** always via `./build.sh install`, which quits a running instance
  before replacing `/Applications/MeetRec.app` (replacing a live bundle can also
  reset TCC permissions).
- **Release:** bump `CFBundleShortVersionString`/`CFBundleVersion` in
  `app/Info.plist`, update `CHANGELOG.md`, then `git tag vX.Y && git push --tags`
  and `gh release create vX.Y dist/MeetRec.dmg`. The landing page's download
  button always points at `releases/latest/download/MeetRec.dmg`.

---

## 8. Key design decisions

- **Local-first, no backend.** Removes an entire class of privacy, cost, and ops
  concerns. The cost is doing ML on-device and shipping/downloading models.
- **Bundled native CLIs over embedding libraries.** `whisper-cli` and
  `llama-server` are subprocesses, not linked libraries. This keeps the Swift
  side simple, isolates crashes/memory, and lets the OS reclaim model memory when
  a process exits (so "LLM only after Whisper" is trivial).
- **llama.cpp over MLX** for the LLM: a stable OpenAI-compatible HTTP surface,
  the same bundling pattern as Whisper, and the widest GGUF model ecosystem.
- **Separate audio tracks until the end.** Mic and system audio are kept as
  distinct tracks and only mixed on stop — this enables the timestamp-offset
  pause and leaves the door open for mic-based "you vs. others" labeling.
- **SQLite + brute-force vectors over a vector DB** — right-sized for a personal
  archive, zero dependencies.
- **Everything is a file next to the recording.** Transcript, summary, video —
  all live beside the `.m4a`, so they sync to Google Drive and are trivially
  inspectable outside the app.

---

## 9. Privacy & network surface

MeetRec makes network requests only for:
1. **Model downloads** (Whisper / Qwen / bge-m3) from Hugging Face — one-time.
2. **`models.json`** manifest + **GitHub Releases** — update checks.
3. **Google Calendar API** — only if the user connects a calendar (read-only).

Audio, video, transcripts, summaries, and the search index never leave the Mac.

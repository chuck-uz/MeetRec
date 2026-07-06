# Contributing / Development guide

How to build, run, and extend MeetRec. For the system design read
[ARCHITECTURE.md](ARCHITECTURE.md); for product usage read [README.md](README.md).

## Prerequisites

- macOS 15+ on **Apple Silicon**.
- Xcode Command Line Tools (`xcode-select --install`) — provides `swift`,
  `codesign`, `hdiutil`, `sips`, `iconutil`.
- The native binaries (`whisper-cli`, `llama-server`) and the VAD model are
  committed under `app/bin/`, so no extra setup is needed to build.

## Project layout

```
app/
  Sources/          Swift source (single SPM executable target "MeetRec")
  bin/              bundled native binaries + VAD model (committed)
  Info.plist        bundle metadata, version, entitlements-free
  AppIcon.icns      generated app icon (make-icon.swift)
  make-icon.swift   generates the icon from code
Package.swift       SPM manifest (FluidAudio dependency, macOS 15 target)
build.sh            assemble .app + sign + build DMG (and `install`)
models.json         remote manifest for auto-updating ML models
docs/               GitHub Pages landing (index.html, privacy.html)
ARCHITECTURE.md     system design (read this first)
CHANGELOG.md        Keep a Changelog format
```

Local-only, git-ignored notes: `PROJECT_CONTEXT.md`, `DEBUG_JOURNAL.md`,
`GOOGLE_VERIFICATION.md`.

## Build & run

```sh
swift build -c release          # compile only (fast iteration)
./build.sh                      # assemble build/MeetRec.app + dist/MeetRec.dmg
./build.sh install              # + replace /Applications/MeetRec.app and launch
```

Always use **`./build.sh install`** to run the real app — it quits any running
instance first. Do **not** replace `/Applications/MeetRec.app` while it's
running, and do not rebuild while MeetRec is open: macOS can reset the Screen
Recording / Microphone permissions if the signed bundle changes under a live
process. See ARCHITECTURE §7 and `DEBUG_JOURNAL.md`.

### Code signing

`build.sh` signs with a stable self-signed certificate named **"MeetRec Dev"**
from the login keychain. This gives a stable *designated requirement* so TCC
permissions survive rebuilds. Without that certificate the script falls back to
ad-hoc signing and prints a warning — expect Screen Recording permission to drop
on every rebuild in that mode.

To set up signing on a fresh machine, either import the backup
(`MeetRec-Dev.p12`) into the login keychain, or create a new self-signed
code-signing certificate and update the leaf hash in `build.sh`. You can override
the identity with `SIGN_IDENTITY=... ./build.sh`.

## Adding a feature — the usual shape

1. **Model/logic** in a new `app/Sources/*.swift`. Long-running or subprocess
   work goes in an `actor` (see `LLMRuntime`, `EmbeddingService`, `ArchiveStore`);
   pure orchestration can be an `enum` with `static` funcs (see `ArchiveIndexer`,
   `Summarizer`).
2. **State** on `AppState` — add `@Published` properties and coordinating methods.
   Persist small settings via `UserDefaults` in a `didSet`. Read heavy work off
   the main actor via `Task { … }`.
3. **UI** — a card in `ContentView` for the main window, or a panel in
   `MeetingsView` / a new `Window` scene in `MeetRecApp`. Follow the existing
   design tokens in `Design` (cyan `#0891B2` / green `#059669`, 12 pt corners,
   `.pointingCursor()` on clickables).
4. **Gate AI features** behind `Hardware.supportsChat` (≥ 16 GB RAM).
5. **Errors** — set `AppState.errorMessage`; it is logged in full automatically.
   Add `Log.info(...)` at meaningful lifecycle points.
6. **Test the risky part empirically** before shipping (see below).

## Testing conventions

There is no XCTest suite; the ML-heavy parts are verified with **throwaway
harnesses** that reuse the real source files + minimal stubs, compiled with
`swiftc -parse-as-library`, run against the real bundled binaries/models. This is
how VAD quality, pause timestamp math, RAG retrieval, and the LLM prompts were
each validated on real inputs. Prefer proving a change on a real recording over
trusting that it compiles.

## Releasing

```sh
# 1. bump version in app/Info.plist (CFBundleShortVersionString + CFBundleVersion)
# 2. update CHANGELOG.md (Keep a Changelog)
./build.sh install                              # rebuild + install (app must be closed)
git add -A && git commit -m "vX.Y: …"
git tag vX.Y && git push && git push origin vX.Y
gh release create vX.Y dist/MeetRec.dmg --title "…" --notes "…"
```

Chain build → commit → release with `&&` so a failed/cancelled build never
publishes a stale DMG. Every push to `main` also redeploys the GitHub Pages
landing (occasional transient GitHub-side deploy failures are re-run, not code
issues).

## Conventions

- Comments and user-facing strings are in Russian; identifiers in English.
- Commits do **not** include Co-Authored-By trailers.
- Keep the app self-contained: bundle native binaries, download models at runtime
  into Application Support, never require Homebrew for end users.

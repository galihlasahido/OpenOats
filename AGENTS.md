# On The Spot

Real-time meeting copilot for macOS. Transcribes conversations, retrieves context from a local knowledge base, and generates talking-point suggestions via LLM.

## Tech Stack

- **Swift/SwiftUI** (Swift 6.2, SPM)
- **macOS 26+**, Apple Silicon
- On-device transcription via Apple Speech framework
- LLM suggestions via OpenRouter API

## Build

```bash
./scripts/build_swift_app.sh
```

This compiles in release mode, creates the `.app` bundle, code-signs it, and installs to `/Applications/On The Spot.app`.

## Project Structure

```
OnTheSpot/
├── Package.swift
├── Sources/OnTheSpot/
│   ├── App/OnTheSpotApp.swift       # Entry point
│   ├── Views/                       # SwiftUI views (ContentView, ControlBar, Settings, etc.)
│   ├── Audio/                       # MicCapture, SystemAudioCapture
│   ├── Transcription/               # TranscriptionEngine (Apple Speech)
│   ├── Intelligence/                # SuggestionEngine, OpenRouterClient, KnowledgeBase
│   ├── Models/                      # Data models, TranscriptStore
│   ├── Settings/AppSettings.swift   # User preferences
│   └── Storage/SessionStore.swift   # Session logging (JSONL)
```

## Other Scripts

- `./scripts/make_dmg.sh` - Create distributable DMG
- `.github/workflows/release-dmg.yml` - CI: build, sign, notarize, attach DMG on release

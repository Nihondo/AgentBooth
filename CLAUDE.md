# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

AgentBooth is a macOS app (SwiftUI, macOS 14+) that runs an AI radio program using Apple Music playlists. It combines AI-generated scripts (via external CLI tools), Gemini TTS, and AppleScript-based music control.

## Commands

### Project generation (required before opening in Xcode)
```bash
xcodegen generate
```

### Build & test
```bash
# Run all tests
xcodebuild -project AgentBooth.xcodeproj -scheme AgentBooth -destination 'platform=macOS' -derivedDataPath /tmp/AgentBoothDerived test

# Run a single test class
xcodebuild -project AgentBooth.xcodeproj -scheme AgentBooth -destination 'platform=macOS' -derivedDataPath /tmp/AgentBoothDerived test -only-testing:AgentBoothTests/RadioOrchestratorTests
```

### Open in Xcode
```bash
open AgentBooth.xcodeproj
```

## Architecture

### Layer structure
```
Domain/           - Protocols.swift (service interfaces), Models.swift (all value types/enums)
App/              - AgentBoothApp.swift (entry point), AppServiceContainer.swift (LiveAppServiceFactory)
Features/         - ContentView + MainViewModel (UI), SettingsView
Services/         - Radio/, Script/, TTS/, Music/, Audio/, Recording/
Infrastructure/   - Settings/AppSettingsStore, Music/AppleScriptExecutor
AgentBoothTests/  - Unit tests + TestDoubles.swift (fakes for all protocols)
```

### Key components

**`RadioOrchestrator`** (`Services/Radio/RadioOrchestrator.swift`) — Swift `actor`. The core of the app. Drives the full radio show lifecycle: opening → intro → playing → transition/outro → closing. Handles overlap modes (sequential, outro_over, intro_over, music_bed, full_radio), music/TTS timing, and fade control. Uses `TimedPreparation` internally to pipeline script generation while music plays.

**`MainViewModel`** (`Features/Main/MainViewModel.swift`) — `@MainActor ObservableObject`. Owns `RadioOrchestrator` and bridges UI state (`RadioState`) to SwiftUI views. Does not contain radio logic.

**`AppServiceFactory` / `LiveAppServiceFactory`** — Dependency injection entry point. `AppServiceContainer.swift` wires up live services. Tests use fakes from `TestDoubles.swift`.

**`ProcessScriptGenerationService`** (`Services/Script/`) — Calls an external CLI subprocess (`claude`, `gemini`, `codex`, or `copilot`) to generate JSON scripts. `ScriptCommandBuilder` assembles the command per CLI type.

**`GeminiTTSService`** (`Services/TTS/`) — Calls Gemini REST API directly to produce WAV audio. Includes retry/fallback model logic.

**`AppleMusicService`** (`Services/Music/`) — Controls Apple Music.app via `AppleScriptExecutor` (Infrastructure layer).

**`AppSettingsStore`** (`Infrastructure/Settings/`) — Persists settings to UserDefaults; stores Gemini API key in Keychain under service name `com.dmng.AgentBooth`.

### Domain models (`Domain/Models.swift`)

All shared value types live here: `TrackInfo`, `RadioScript`, `RadioState`, `AppSettings` (and its sub-structs), `OverlapMode`, `RadioPhase`, `PrimaryControlState`, `ScriptCLIKind`.

### Script JSON format

The CLI must return:
```json
{
  "dialogues": [{"speaker": "male"|"female", "text": "..."}],
  "summaryBullets": ["...", "..."]
}
```
`summaryBullets` is fed back into the next prompt only when the artist/album repeats. A legacy format with only `dialogues` is also accepted.

### Overlap modes

| Mode | Behavior |
|---|---|
| `sequential` | Talk then music, fully separated |
| `outro_over` | Talk overlaps the end of the track |
| `intro_over` | Music starts near the end of talk |
| `music_bed` | Music plays quietly under talk |
| `full_radio` | Combines intro_over + outro_over + ducking |

## Concurrency model

- `RadioOrchestrator` is a Swift `actor` — call its methods with `await` from `@MainActor` context in `MainViewModel`.
- `@MainActor` is required for all UI-touching code (`MainViewModel`, `AppSettingsStore`, views).
- All service protocols are `Sendable`.

## Testing

`AgentBoothTests/TestDoubles.swift` contains fakes for all protocols (`FakeMusicService`, `FakeTTSService`, `FakeScriptGenerationService`, `ConditionalDelayTTSService`, etc.). Use these rather than mocking frameworks.

## Constraints

- `YouTubeMusicPlaceholderService` exists as a stub only — not implemented.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX: NO`) — Mac App Store distribution is not yet supported.
- The project is managed by XcodeGen (`project.yml`). Edit `project.yml` for build settings changes, then regenerate.
- External CLIs (`claude`, `gemini`, `codex`, `copilot`) must be installed in the user's environment.

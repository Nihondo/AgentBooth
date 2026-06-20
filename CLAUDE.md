# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

AgentBooth is a macOS app (SwiftUI, macOS 14+) that runs an AI radio program using Apple Music, YouTube Music, or Spotify playlists. It combines AI-generated scripts (via external CLI tools), Gemini TTS, and music control via AppleScript (Apple Music) or WKWebView JS injection / DOM automation (YouTube Music, Spotify).

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
Features/         - ContentView + MainViewModel (UI), SettingsView, NowPlayingBar, TrackListView, YouTubeMusicBrowser/, SpotifyBrowser/
Services/         - Radio/, Script/, TTS/, Music/, Audio/, Context/, Recording/
Infrastructure/   - Settings/AppSettingsStore, Music/AppleScriptExecutor + AppleMusicArtworkFetcher, YouTube/, Spotify/
AgentBoothTests/  - Unit tests + TestDoubles.swift (fakes for all protocols)
```

### Key components

**`RadioOrchestrator`** (`Services/Radio/RadioOrchestrator.swift`) — Swift `actor`. The core of the app. Drives the full radio show lifecycle: opening → intro → playing → transition/outro → closing. It keeps one active narration playback handle, prepares the next narration while music plays, waits instead of skipping delayed TTS, extends the current track up to its natural end when early cutoff would otherwise interrupt the flow, and emits cuesheet events for track, fade, and narration timing. Service-specific startup latency is injected via `MusicPlaybackProfile`, so the orchestrator no longer switches on the concrete music backend kind. Supports two script generation modes: on-demand (scripts are generated one at a time during playback) and pre-generate (all scripts are generated upfront, presented for review/editing, then cached for playback). In pre-generate mode, the actor suspends via `CheckedContinuation` until the user approves, and the existing playback loop picks up cached scripts transparently via `preGeneratedSegments[SegmentKey]` lookups in each prepare method.

**`MainViewModel`** (`Features/Main/MainViewModel.swift`) — `@MainActor ObservableObject`. Owns `RadioOrchestrator` and bridges UI state (`RadioState`) to SwiftUI views. Does not contain radio logic. Exposes `reviewItems` / `isReviewing` for the pre-generate script review sheet, and `approveScriptReview()` / `cancelScriptReview()` to drive the orchestrator continuation.

**`ScriptReviewView`** (`Features/Main/ScriptReviewView.swift`) — SwiftUI sheet for reviewing and editing pre-generated scripts before playback. Displays all TTS inputs: scene direction (TTS voice-acting guidance, editable), voice names (read-only), and dialogue lines (editable text). Presented as a `.sheet` on `ContentView` when `isReviewing` is true.

**`AppServiceFactory` / `LiveAppServiceFactory`** — Dependency injection entry point. `AppServiceContainer.swift` wires up live services plus `MusicPlaybackProfile` values. Tests use fakes from `TestDoubles.swift`.

**`ProcessScriptGenerationService`** (`Services/Script/`) — Calls an external CLI subprocess (`claude`, `gemini`, `codex`, or `copilot`) to generate JSON scripts. `ScriptCommandBuilder` assembles the command per CLI type. Each script session folder also gets a `cuesheet.txt` file with CLI timing and related playback events.

**`RealtimeContextProvider`** (`Services/Context/`) — Builds prompt context from local `Date()` values: hour, weekday, month, season, and optional `RadioShowSettings.locationName`. AgentBooth does not call a weather API; when a location is set, prompts allow the selected CLI to mention current weather only if it can verify it.

**`TimeBasedDirectionResolver`** (`Services/Context/`) — Applies `DirectionSettings.timeBasedPresets` by resolving the current `TimeBand` and appending the matching preset to `sceneDirection`. This only affects TTS voice-acting direction; `scriptDirection` (content/topic guidance for script generation) is not modified by time-band presets.

**`GeminiTTSService`** (`Services/TTS/`) — Calls Gemini REST API directly to produce WAV audio. Includes retry/fallback model logic and writes per-attempt status/fallback details to the session cuesheet.

**`SystemBedAudioPlaybackService`** (`Services/Audio/`) — Separate BGM / jingle playback service built on `AVAudioPlayer`. It does not replace `SystemAudioPlaybackService` or mix PCM with TTS. Bed BGM loops only in narration sections where external music is not playing, fades out before track start, and follows pause / resume / stop. Jingles are one-shot cues for opening and closing only.

**`AudioAssetPicker`** (`Services/Audio/`) — Resolves `AudioAssetSource` settings into playable audio file URLs. File sources must point to an existing audio file; directory sources choose one audio file from the directory at playback time. Keep random asset selection here rather than in `RadioOrchestrator`.

**`AppleMusicService`** (`Services/Music/`) — Controls Apple Music.app via `AppleScriptExecutor` (Infrastructure layer).

**`YouTubeMusicService`** (`Services/Music/`) — `@MainActor final class`. Implements `MusicService` for YouTube Music. Delegates to `YouTubeMusicAPIFetcher` (playlist/track fetch) and `YouTubeMusicPlayerController` (playback control). All operations run through `store.playbackWebView`.

**`SpotifyMusicService`** (`Services/Music/`) — `@MainActor final class`. Implements `MusicService` for Spotify by navigating `open.spotify.com` in `store.playbackWebView`, scraping the sidebar / tracklist / player DOM, and clicking DOM controls for playback.

**`YouTubeMusicWebViewStore`** (`Services/Music/`) — Manages two WKWebViews sharing `WKWebsiteDataStore.default()`:
- `webView` (login UI, shown in browser window)
- `playbackWebView` (playback-only, always in offscreen NSWindow for audio)

Key detail: `setupOffscreenWindow()` is called via `DispatchQueue.main.async` in `init` — must be deferred or SwiftUI's WindowGroup main window disappears.

**`SpotifyWebViewStore`** (`Services/Music/`) — Mirrors the YouTube Music store structure for Spotify Web Player. It keeps one visible login web view and one offscreen playback web view, sharing the default website data store so login sessions stay in sync.

**`YouTubeMusicAPIFetcher`** (`Services/Music/`) — Fetches playlists and tracks from YouTube Music internal API (`/youtubei/v1/browse`) via JS injection into `playbackWebView`. Authentication: `SAPISIDHASH` header = `"SAPISIDHASH {timestamp}_{SHA1(timestamp + " " + SAPISID + " " + origin)}"` computed from `__Secure-3PAPISID` cookie using `crypto.subtle.digest("SHA-1")` (ytmusicapi-compatible).

**`YouTubeMusicPlayerController`** (`Services/Music/`) — Controls playback by navigating `window.location.href` and manipulating `document.querySelector('video')` via JS.

**`YouTubeMusicJSScripts`** (`Infrastructure/YouTube/`) — All JS constants. `sharedHelperJS` provides `buildContext()`, `browseUrl()`, `buildAuthHeader()`, `ytmFetch()`. Playlist path: `musicTwoRowItemRenderer.title.runs[0].navigationEndpoint.browseEndpoint.browseId`. Track path uses `twoColumnBrowseResultsRenderer.secondaryContents` (not singleColumn).

**`YouTubeMusicScriptRunner`** (`Infrastructure/YouTube/`) — `callAsyncJavaScript` + `CheckedContinuation` wrapper (mirrors AgentLimits `WebViewScriptRunner`).

**`SpotifyDOMScripts`** (`Infrastructure/Spotify/`) — JS constants used to extract sidebar playlists, playlist tracks, player status, and to click Spotify Web Player controls. This is intentionally DOM-fragile and should be treated as an MVP integration.

**`SpotifyScriptRunner`** (`Infrastructure/Spotify/`) — `callAsyncJavaScript` + `CheckedContinuation` wrapper for Spotify DOM scripts.

**`AppSettingsStore` / `ShowProfileStore`** (`Infrastructure/Settings/`) — Persists global settings to UserDefaults under `app_settings`, show profiles to `show_profiles`, and Gemini API keys to Keychain under service name `com.dmng.AgentBooth`. `currentSettings` is always the global settings snapshot with the active `ShowProfile` applied. Profile-scoped fields are `RadioShowSettings`, `PersonalitySettings`, `DirectionSettings`, `VoiceSettings`, `VolumeSettings`, `BGMSettings`, and `defaultOverlapMode`; service login, TTS credentials, script CLI, and recording output remain global.

**`NowPlayingBar`** (`Features/Main/NowPlayingBar.swift`) — SwiftUI `View`. 常時表示。`radioState.currentTrack` があればそれを、なければ `displayTracks.first`（プレイリスト読み込み後すぐ）を表示。`isAppleMusic && artworkURL == nil` の場合、`.task(id: track.id)` で `AppleMusicArtworkFetcher` を呼び出してアートワークを取得・キャッシュする。

**`AppleMusicArtworkFetcher`** (`Infrastructure/Music/AppleMusicArtworkFetcher.swift`) — `NSAppleScript` 経由でアートワークを取得するユーティリティ（`enum` namespace）。`fetchArtwork(forTrack:)` は `playlistName / name / artist` でプレイリスト内のトラックを直接検索するため、カレントトラック設定不要・再生前でも取得可。バックグラウンドスレッド (`DispatchQueue.global`) で実行。

### Domain models (`Domain/Models.swift`)

All shared value types live here: `TrackInfo`, `RadioScript`, `RadioState`, `AppSettings`, `ShowProfile` (and their sub-structs including `RadioShowSettings`, `DirectionSettings`, `BGMSettings` / `AudioAssetSource`), `TimeBand`, `OverlapMode`, `ScriptGenerationMode`, `RadioPhase`, `PrimaryControlState`, `ScriptCLIKind`, `ReviewScriptItem`.

### Direction settings

`DirectionSettings` holds two independent direction fields:

| Field | Purpose | Consumed by |
|---|---|---|
| `scriptDirection` | Content/topic guidance for the CLI script generator (e.g. themes, talking points, tone of dialogue) | `PromptBuilder` only |
| `sceneDirection` | Voice-acting / delivery guidance for TTS (e.g. speak softly, excited tone) | `GeminiTTSService` only |

`timeBasedPresets` are appended to `sceneDirection` only (via `TimeBasedDirectionResolver`); they do not affect `scriptDirection`. In the pre-generate review sheet, only `sceneDirection` is editable per-segment because script generation has already completed.

### Script JSON format

The CLI must return:
```json
{
  "dialogues": [{"speaker": "male"|"female", "text": "..."}],
  "summaryBullets": ["...", "..."]
}
```
`summaryBullets` is stored in the current in-memory show topic ledger and fed into transition prompts so later talk can avoid repeating earlier topics. Same-artist / same-album repeats also receive focused continuity notes from `artistTopicHistory` / `albumTopicHistory`. A legacy format with only `dialogues` is also accepted.

### Overlap modes

| Mode | Behavior |
|---|---|
| `enabled` | Talk may overlap the tail of the current track and the lead-in of the next track |
| `disabled` | Talk and music stay separated |

### Script generation modes

| Mode | Behavior |
|---|---|
| `onDemand` | Default. Scripts are generated one segment at a time during playback (next narration is prepared while music plays). |
| `preGenerate` | All scripts (opening, transitions, closing) are generated sequentially before playback starts. The user reviews and can edit dialogue text and TTS scene direction in a sheet. TTS is not pre-generated — it runs on-demand during playback using cached scripts. |

Pre-generate mode uses `preGeneratedSegments: [SegmentKey: CachedSegment]` inside `RadioOrchestrator`. Each `CachedSegment` holds the script and the direction-adjusted `AppSettings` snapshot captured at generation time. The existing prepare methods check this cache first; on a hit they skip `scriptService.generateXxx` and use the cached script + settings for TTS. The playback loop itself is unchanged. After review approval, the edited pre-generated scripts are also persisted through `PreGeneratedScriptStore` at `Application Support/AgentBooth/cache/pregenerated_session.json`; API keys are stripped from saved `AppSettings` and rehydrated from the current runtime `AppSettings` when a saved session is restored.

At the next pre-generate start, if the saved `playlistName` and track fingerprint (`tracks.map(\.id).joined(separator: "\n")`) match the current run, `RadioOrchestrator` asks the UI whether to reuse the saved scripts. Reuse restores `preGeneratedSegments` and still opens the review sheet before playback; decline archives the active saved session and regenerates. Normal show completion also archives the active cache so it is no longer offered for reuse. Manual stop and playback errors keep the active cache in place. The live store archives by renaming `pregenerated_session.json` to a timestamped JSON file in the same cache directory.

The review handshake uses `CheckedContinuation<[ReviewScriptItem], Error>` — the actor suspends in `awaitScriptReview()` and resumes when `approveScripts(_:)` or `cancelReview()` is called. The reuse prompt uses `CheckedContinuation<Bool, Error>` and resumes through `confirmReuse()` / `declineReuse()`. `stopShow()` calls `failPendingContinuations()` to prevent continuation leaks. All resume paths nil-out their continuation before resuming to prevent double-resume crashes.

`ScriptGenerationMode` is a profile-scoped setting (`AppSettings.defaultScriptGenerationMode` / `ShowProfile.defaultScriptGenerationMode`), persisted the same way as `defaultOverlapMode`.

### BGM / jingle behavior

- TTS playback stays on `AudioPlaybackServiceProtocol.play(wavData:)`; BGM and jingles are controlled through `BedAudioPlaybackServiceProtocol`.
- Opening jingle and closing jingle are individually enabled. Transition narrations must not play jingles.
- Bed BGM is allowed only when no external music track is playing. Before starting a track, call `fadeOutAndStopBed(settings:)`.
- In overlap mode, transition narration starts with bed disabled while the current track is still playing; after the track has fully stopped, start bed for the remaining narration if TTS is still active.
- If closing jingle is enabled while music is still playing, the orchestrator stops/fades the track before the jingle and closing narration.
- BGM / jingle failures should skip only that cue and must not fail TTS narration playback.

## Concurrency model

- `RadioOrchestrator` is a Swift `actor` — call its methods with `await` from `@MainActor` context in `MainViewModel`.
- `@MainActor` is required for all UI-touching code (`MainViewModel`, `AppSettingsStore`, views).
- All service protocols are `Sendable`.
- `MusicService.play(track:)` is expected to start the selected track from the beginning; the orchestrator does not seek back to `0` after calling it.

## Testing

`AgentBoothTests/TestDoubles.swift` contains fakes for all protocols (`FakeMusicService`, `FakeTTSService`, `FakeScriptGenerationService`, `ConditionalDelayTTSService`, etc.). Use these rather than mocking frameworks.

## Constraints

- App Sandbox is disabled (`ENABLE_APP_SANDBOX: NO`) — Mac App Store distribution is not yet supported.
- The project is managed by XcodeGen (`project.yml`). Edit `project.yml` for build settings changes, then regenerate.
- External CLIs (`claude`, `gemini`, `codex`, `copilot`) must be installed in the user's environment.
- YouTube Music requires manual login via Settings → 音楽 → "YouTube Music でログイン" before use.
- Spotify requires manual login via Settings → 音楽 → "Spotify でログイン" before use.
- Spotify automation is DOM-based. Selector breakage is expected when Spotify updates the Web Player UI.

## Sparkle (Automatic Updates)

Sparkle is integrated via SPM (declared in `project.yml` packages section). Key files:

- `App/AppUpdateController.swift` — singleton wrapping `SPUStandardUpdaterController`; publishes `canCheckForUpdates`, `lastUpdateCheckDate`, `automaticChecksEnabled` via Combine KVO
- `Features/Settings/UpdateSettingsView.swift` — Settings tab for version info and update controls
- Info.plist keys are generated from `project.yml` `info.properties` section

### EdDSA Key Management

`SUPublicEDKey` in `project.yml` is the Sparkle EdDSA public key used when generating `Info.plist`. If the private key is lost or the update signing key must be rotated:

1. Generate the key pair with Sparkle's bundled tool:
   ```bash
   # Path varies by SPM cache — find generate_keys under .build/
   find . -name generate_keys -path "*/Sparkle*" | head -1
   ./path/to/generate_keys
   ```
2. Save the **private key** to the macOS Keychain (the tool prompts for this automatically).
3. Replace `SUPublicEDKey` in `project.yml` with the **public key** output, then run `xcodegen generate`.
4. If the private key is ever lost, generate a new pair and ship a transitional release before retiring the old key.

### Appcast

The feed URL is `https://products.desireforwealth.com/appcast/agentbooth/appcast.xml`. This file does not yet exist. Use Sparkle's `generate_appcast` tool (or adapt `AgentLimits/Products/tools/build_appcast.py`) to create and upload it for each release.

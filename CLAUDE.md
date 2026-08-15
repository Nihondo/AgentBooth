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
Domain/           - Protocols.swift (service interfaces), Models.swift (all value types/enums), ReviewDrafts.swift (script review UI-only editing types)
App/              - AgentBoothApp.swift (entry point), AppServiceContainer.swift (LiveAppServiceFactory)
Features/         - ContentView + MainViewModel (UI), SettingsView, NowPlayingBar, TrackListView, YouTubeMusicBrowser/, SpotifyBrowser/, Main/Review/ (pre-generate script review window)
Services/         - Radio/, Script/, TTS/, Music/, Audio/, Context/, Recording/
Infrastructure/   - Settings/AppSettingsStore, Music/AppleScriptExecutor + AppleMusicArtworkFetcher, YouTube/, Spotify/
AgentBoothTests/  - Unit tests + TestDoubles.swift (fakes for all protocols)
```

### Key components

**`RadioOrchestrator`** (`Services/Radio/RadioOrchestrator.swift`) — Swift `actor`. The core of the app. Drives the full radio show lifecycle: opening → intro → playing → transition/outro → closing. It keeps one active narration playback handle, prepares the next narration while music plays, waits instead of skipping delayed TTS, extends the current track up to its natural end when early cutoff would otherwise interrupt the flow, and emits cuesheet events for track, fade, and narration timing. Music fades are driven by active elapsed time rather than a fixed count of backend calls, exclude paused time, and fall back to the last orchestrator-set volume when a backend cannot report its current volume. Non-overlap transitions fade a track before stopping unless it already reached its natural end. Service-specific startup latency is injected via `MusicPlaybackProfile`, so the orchestrator no longer switches on the concrete music backend kind. Supports two script generation modes: on-demand (scripts are generated one at a time during playback) and pre-generate (all scripts are generated upfront, presented for review/editing, then cached for playback). In pre-generate mode, the actor suspends via `CheckedContinuation` until the user approves, and the existing playback loop picks up cached scripts transparently via `preGeneratedSegments[SegmentKey]` lookups in each prepare method.

**`MainViewModel`** (`Features/Main/MainViewModel.swift`) — `@MainActor ObservableObject`. Owns `RadioOrchestrator` and bridges UI state (`RadioState`) to SwiftUI views. Does not contain radio logic. Exposes `isReviewing` (window open/close trigger) and `reviewViewModel: ScriptReviewViewModel?` (owns the actual review draft state) for the pre-generate script review window, and `approveScriptReview()` / `cancelScriptReview()` to drive the orchestrator continuation. Closing the review window does not clear `reviewViewModel` — edits and the show's suspended state are preserved until the user explicitly approves or cancels, or the show stops through another path (e.g. the global Stop button), which also clears review state.

**`ScriptReviewView`** (`Features/Main/Review/ScriptReviewView.swift`) — Independent, freely resizable window (`Window(id: WindowIdentifier.scriptReview)`, opened via `openWindow`/`dismissWindow` from `ContentView`, not a `.sheet`) for reviewing and editing pre-generated scripts before playback. Two-pane `NavigationSplitView`: a segment list sidebar and a detail pane that renders only the selected segment (`ScriptReviewSegmentEditor`, `Features/Main/Review/`) via `ScrollView { VStack }` rather than `List`, to minimize the number of live `TextEditor`/`TextField` instances.

**`ScriptReviewViewModel`** (`Features/Main/Review/ScriptReviewViewModel.swift`) — `@MainActor ObservableObject` that owns the review draft (`[ReviewSegmentDraft]`, `Domain/ReviewDrafts.swift`). **Design contract — do not break**: `segments` is deliberately not `@Published`. Publishing on every keystroke was the root cause of a bug where the caret jumped to the end of the text field on every character typed (SwiftUI rebuilding every `TextEditor`/`TextField` in the tree on each `objectWillChange`, causing NSTextView to have its string reassigned and its selection reset). `updateLineText(segmentID:lineID:text:)` / `updateSceneDirection(segmentID:text:)` mutate `segments` directly with no `objectWillChange` firing. Only structural changes bump `@Published var structureRevision`, which feeds `ReviewSeedToken` (`targetID` + `structureRevision`). The leaf editor `DraftTextEditor` (`Features/Main/Review/DraftTextEditor.swift`) holds its own local `@State` text buffer and only overwrites it from the external `seed` value when its `seedToken` changes — this is the one path by which structural edits (not keystrokes) reach the UI. `contentRevision` is a separate `@Published` counter, bumped on a 0.5s debounce after text edits, meant for derived UI (hit counts, TTS input preview) that may lag typing; it is intentionally excluded from `ReviewSeedToken` so it never forces a re-seed. Regression coverage lives in `AgentBoothTests/ScriptReviewViewModelTests.swift` (`testUpdateLineTextDoesNotPublishObjectWillChange` / `testUpdateSceneDirectionDoesNotPublishObjectWillChange` assert zero `objectWillChange` emissions on text edits — do not remove).

Structural edits implemented so far: `appendLine` / `insertLine(in:after:speaker:)` / `removeLine` (refuses to delete a segment's last remaining line, to avoid sending an empty transcript to TTS) / `toggleSpeaker` / `setSpeaker(_:of:in:)`. Drag-and-drop is the only line-reordering UI (`ScriptReviewSegmentEditor`, mirroring the `.onDrag`/`.onDrop(delegate:)` pattern from `TTSCredentialSetsEditor`): `beginLineDragReorder()` pushes exactly one undo snapshot when the drag starts, and the repeated `reorderLineDuringDrag(_:in:to:)` calls fired by `DropDelegate.dropEntered` while hovering over rows do **not** push additional snapshots — otherwise a single drag gesture would flood the undo stack. `undoLastStructuralChange()` pops one snapshot (stack capped at 20) and restores `segments` wholesale, then bumps `structureRevision` once.

**Search & replace** (`Features/Main/Review/ReviewSearchEngine.swift`, pure functions over `NSRange`/UTF-16 offsets) searches scene direction + every dialogue line across **all** segments, in segment → sceneDirection → line order. `ScriptReviewViewModel.search: ReviewSearchState` holds the query/replacement/case-sensitivity/bar-visibility; `matches` is a computed property (not cached) recomputing on every access. `search.currentMatchIndex` defaults to **-1**, a sentinel meaning "no jump performed yet" — both the search bar's `n/total` label and `replaceCurrentMatch()` treat a negative index as index 0, so typing a query and immediately pressing Replace (without ever pressing next/prev) acts on the first hit, and the very first ⌘G press lands on the first hit rather than skipping to the second. `focusNextMatch()`/`focusPreviousMatch()` update `selectedSegmentID` and publish a `focusRequest` (segment + `ReviewMatch.Target` + an incrementing `token`, so jumping to the same target twice in a row still fires `onChange`); `ScriptReviewSegmentEditor` observes it and moves a single `@FocusState private var focusedTarget: ReviewMatch.Target?` that every `DraftTextEditor` in the pane is wired to via `.focused(_:equals:)` (`DraftTextEditor` takes the binding + its own target value as init parameters). `replaceCurrentMatch()`/`replaceAllMatches()` push one undo snapshot and bump `structureRevision` (they go through the same "structural change" path as line edits, not the no-publish text-edit path, since they must force-reseed every affected `DraftTextEditor`). `replaceAllMatches()` delegates to `NSString.replacingOccurrences(of:with:options:range:)` rather than a manual per-range loop, so a replacement string that itself contains the query (e.g. "A" → "AA") cannot cause runaway re-expansion. `⌘F` toggles the bar, `Esc` (`.onExitCommand`) closes it, `⌘G`/`⇧⌘G` navigate — wired as invisible always-active `Button`s with `.keyboardShortcut(...)` in `ScriptReviewView`'s `.background`, so they work regardless of which field currently has focus.

**`AppServiceFactory` / `LiveAppServiceFactory`** — Dependency injection entry point. `AppServiceContainer.swift` wires up live services plus `MusicPlaybackProfile` values. Tests use fakes from `TestDoubles.swift`.

**`ProcessScriptGenerationService`** (`Services/Script/`) — An actor that calls an external CLI subprocess (`claude`, `gemini`, `codex`, or `copilot`) to generate JSON scripts. `ScriptCommandBuilder` assembles the command per CLI type. stdout and stderr must be drained concurrently while the child process runs, and process termination must be awaited asynchronously; reverting to `waitUntilExit()` followed by pipe reads can deadlock on output larger than the OS pipe buffer. Actor isolation also protects the shared script-session log. Each script session folder gets a `cuesheet.txt` file with CLI timing and related playback events.

**`PromptBuilder`** (`Services/Script/`) — Builds the script-generation prompts. Prompt realtime context remains available as show info, but non-empty `DirectionSettings.scriptDirection` is emitted with an explicit priority block: if it specifies a time of day, greeting, or mood, that show-time direction overrides the realtime context and the CLI should avoid conflicting realtime expressions.

**`RealtimeContextProvider`** (`Services/Context/`) — Builds prompt context from local `Date()` values: hour, weekday, month, season, and optional `RadioShowSettings.locationName`. AgentBooth does not call a weather API; when a location is set, prompts allow the selected CLI to mention current weather only if it can verify it.

**`TimeBasedDirectionResolver`** (`Services/Context/`) — Applies `DirectionSettings.timeBasedPresets` by resolving the current `TimeBand` and appending the matching preset to `sceneDirection`. This only affects TTS voice-acting direction; `scriptDirection` (content/topic guidance for script generation) is not modified by time-band presets.

**`GeminiTTSService`** (`Services/TTS/`) — Calls Gemini REST API directly to produce WAV audio. Includes retry/fallback model logic and writes per-attempt status/fallback details to the session cuesheet.

**`SystemBedAudioPlaybackService`** (`Services/Audio/`) — Separate BGM / jingle playback service built on `AVAudioPlayer`. It does not replace `SystemAudioPlaybackService` or mix PCM with TTS. Bed BGM loops only in narration sections where external music is not playing, fades out before track start, and follows pause / resume / stop. A fade generation token makes the newest bed fade authoritative and prevents overlapping fade loops from fighting over volume. Jingles are one-shot cues for opening and closing only; `prepareJingle` selects and retains the exact asset whose duration was measured, and `playJingle` consumes that prepared selection once.

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

**`AppSettingsStore` / `ShowProfileStore`** (`Infrastructure/Settings/`) — Persists global settings to UserDefaults under `app_settings`, show profiles to `show_profiles`, and Gemini API keys to Keychain under service name `com.dmng.AgentBooth`. `SettingsView` debounces draft persistence by 0.5 seconds and flushes the pending draft when the view closes; do not restore per-keystroke persistence. `AppSettingsStore` rewrites the Keychain bundle only when `ttsCredentialSets` changes. `currentSettings` is always the global settings snapshot with the active `ShowProfile` applied. Profile-scoped fields are `RadioShowSettings`, `PersonalitySettings`, `DirectionSettings`, `VoiceSettings`, `VolumeSettings`, `BGMSettings`, and `defaultOverlapMode`; service login, TTS credentials, script CLI, and recording output remain global.

**Recording output lifecycle** — `RadioOrchestrator` keeps the active recording URL in actor-isolated state while `RadioState.recordingOutputURL` remains hidden during recording. `finalizeRecording()` restores that URL to `RadioState` after `stopRecording()` so the completed file remains available to the UI. Do not derive the final URL from the temporarily-cleared UI state.

**`NowPlayingBar`** (`Features/Main/NowPlayingBar.swift`) — SwiftUI `View`. 常時表示。`radioState.currentTrack` があればそれを、なければ `displayTracks.first`（プレイリスト読み込み後すぐ）を表示。`isAppleMusic && artworkURL == nil` の場合、`.task(id: track.id)` で `AppleMusicArtworkFetcher` を呼び出してアートワークを取得・キャッシュする。

**`AppleMusicArtworkFetcher`** (`Infrastructure/Music/AppleMusicArtworkFetcher.swift`) — `NSAppleScript` 経由でアートワークを取得するユーティリティ（`enum` namespace）。`fetchArtwork(forTrack:)` は `playlistName / name / artist` でプレイリスト内のトラックを直接検索するため、カレントトラック設定不要・再生前でも取得可。バックグラウンドスレッド (`DispatchQueue.global`) で実行。

### Domain models (`Domain/Models.swift`)

All shared value types live here: `TrackInfo`, `RadioScript`, `RadioState`, `AppSettings`, `ShowProfile` (and their sub-structs including `RadioShowSettings`, `DirectionSettings`, `BGMSettings` / `AudioAssetSource`), `TimeBand`, `OverlapMode`, `ScriptGenerationMode`, `RadioPhase`, `PrimaryControlState`, `ScriptCLIKind`, `ReviewScriptItem` (carries `segmentKey`, the resolved pronunciation dictionary, and its application mode), `PronunciationEntry` / `PronunciationScope` / `PronunciationApplicationMode`.

`Domain/ReviewDrafts.swift` holds UI-only editing types for the script review window: `ReviewSpeaker`, `ReviewLineDraft`, `ReviewSegmentDraft`, `ReviewSeedToken`, `ReviewMatch`, `ReviewSearchState`, `ReviewValidationIssue`. **Constraint**: `DialogueLine` / `RadioScript` are never modified to carry UI concerns (e.g. a stable per-line `id`) — they are an external contract shared with (a) the pre-generated script JSON persisted at `pregenerated_session.json` and (b) the JSON returned by external script-generation CLIs. `AgentBoothTests/PreGeneratedScriptStoreTests.swift` round-trips `PersistedScriptSession` through encode→decode and asserts full equality, which a synthesized `id: UUID` on `DialogueLine` would break. `ReviewLineDraft` supplies the stable identity the review UI needs instead, and `ReviewSegmentDraft.makeReviewScriptItem(id:droppingEmptyLines:)` converts back to a `RadioScript` by cloning `segmentType` / `summaryBullets` / `track` from the original and replacing only `dialogues`.

### Direction settings

`DirectionSettings` holds two independent direction fields:

| Field | Purpose | Consumed by |
|---|---|---|
| `scriptDirection` | Content/topic guidance for the CLI script generator (e.g. themes, talking points, tone of dialogue) | `PromptBuilder` only |
| `sceneDirection` | Voice-acting / delivery guidance for TTS (e.g. speak softly, excited tone) | `GeminiTTSService` only |

`timeBasedPresets` are appended to `sceneDirection` only (via `TimeBasedDirectionResolver`); they do not affect `scriptDirection`. In the pre-generate review window, only `sceneDirection` is editable per-segment because script generation has already completed.

When `scriptDirection` includes an explicit time-of-day instruction, `PromptBuilder` treats it as higher priority than the realtime hour in the show info. Keep realtime context in prompts for reference, but do not let it override user-specified show-time direction.

### Pronunciation dictionary

`DirectionSettings.pronunciationEntries` (this show only) and `AppSettings.globalPronunciationEntries` (all shows — deliberately **not** part of `ShowProfile`, so it survives profile switches and isn't duplicated by `ShowProfile.init(id:name:settings:)` / `applyingProfile(_:)`) each hold `[PronunciationEntry]` (`source`, `reading`, `isEnabled`, `note`). `DirectionSettings.pronunciationApplicationMode` is profile-scoped and selects either instruction mode (the backward-compatible default) or TTS-transcript replacement mode. Neither mode rewrites `RadioScript` or the persisted CLI JSON.

- **`PronunciationDictionaryResolver`** (`Services/TTS/PronunciationDictionaryResolver.swift`) — pure functions that merge the two scopes into the effective dictionary actually sent to TTS. Rule: entries with `isEnabled == false` or empty `source`/`reading` are dropped; within one scope a duplicate `source` is last-wins; across scopes a conflicting `source` is resolved in favor of the profile (this-show) entry, but its position in the merged list stays wherever the global entry was (a swap-in-place, not an append) — global-only and profile-only entries keep their natural order. Keys are compared via `normalizedSource(_:)` (trim + NFC).
- **Applies to TTS input only.** `PromptBuilder` (script generation) never receives the dictionary or application mode; the original script text remains untouched.
- **`TTSInputComposer`** (`Services/TTS/TTSInputComposer.swift`) builds the actual text sent to Gemini TTS, shared by `GeminiTTSService` and the review window's input preview so "what you see is what gets sent." In `.instruction`, output stays byte-for-byte compatible: `Direction:` → applicable pronunciation rules → transcript. In `.replaceTranscript`, the rule block is omitted and matching source text is replaced with its reading only in the generated transcript; `Direction:` is still included. Replacement is case-sensitive, NFC-normalized, leftmost/longest at each position, and single-pass so inserted readings are never replaced recursively.
- Settings UI: `Features/Settings/PronunciationDictionaryEditor.swift` (mirrors `TTSCredentialSetsEditor`'s drag-to-reorder pattern), embedded twice in `SettingsView`'s `.pronunciation` category — once bound to `$draftSettings.globalPronunciationEntries` ("共通（全番組）") and once to `$draftSettings.directionSettings.pronunciationEntries` ("この番組のみ"). A profile-scoped application-mode picker controls the merged effective dictionary. The category lives under `showProfileCategories` purely for screen placement; storage scope is determined by each binding.
- In the review window, `ReviewScriptItem` carries the **already-resolved** effective dictionary and application mode for each segment. On approval, `RadioOrchestrator.applyEditedSegments` writes both back into the cached narration settings while zeroing `globalPronunciationEntries`, so playback exactly matches the review preview. `restorePreGeneratedSegments(from:)` re-applies the *current* live dictionary and mode (via `AppSettings.applyingCurrentPronunciationDictionary(from:)`) over the saved session, so later pronunciation fixes and mode changes take effect on reuse.

**Segment and line preview playback** — `ScriptReviewViewModel.requestSegmentPreview(_:)` lets the reviewer hear a whole segment, while `requestLinePreview(_:in:)` sends only the selected line's `DialogueLine` to TTS. Both paths share the same guardrails: (1) a confirmation alert ("consumes one API call") unless the user already chose "試聴する（以後確認しない）" for this review session (`skipsPreviewConfirmation`, in-memory only — not `@AppStorage`) or the show is in test mode (`isTestMode`, which never hits the real API so confirming would be misleading); (2) target-specific caches keyed by a content hash of scene direction + application mode + the target dialogue speaker/text + pronunciation entries — an unchanged target replays its cached WAV instead of re-synthesizing; (3) only one segment-or-line preview in flight at a time — starting another preview cancels the task and stops the previous audio service before playback; (4) preview controls are disabled whenever `canPreviewSegments` is false (no active TTS credential set and not in test mode), and empty lines cannot be previewed. Preview always gets a **fresh** `TTSService`/`AudioPlaybackServiceProtocol` instance from `serviceFactory` (or `TestModeTTSService`/`TestModeAudioPlaybackService` under `isTestMode`) rather than reusing a shared one — `GeminiTTSService` has a same-instance `successfulCallThrottleInterval` (60s) meant to pace narration calls during a live show, and reusing that instance for previews would make the reviewer wait up to a minute between preview presses.

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
| `preGenerate` | All scripts (opening, transitions, closing) are generated sequentially before playback starts. The user reviews and can edit dialogue text and TTS scene direction in an independent review window (`Features/Main/Review/ScriptReviewView.swift`, not a sheet). TTS is not pre-generated — it runs on-demand during playback using cached scripts. |

Pre-generate mode uses `preGeneratedSegments: [SegmentKey: CachedSegment]` inside `RadioOrchestrator`. Each `CachedSegment` holds the script and the direction-adjusted `AppSettings` snapshot captured at generation time. The existing prepare methods check this cache first; on a hit they skip `scriptService.generateXxx` and use the cached script + settings for TTS. The playback loop itself is unchanged. After review approval, the edited pre-generated scripts are also persisted through `PreGeneratedScriptStore` at `Application Support/AgentBooth/cache/pregenerated_session.json`; API keys are stripped from saved `AppSettings` and rehydrated from the current runtime `AppSettings` when a saved session is restored.

At the next pre-generate start, if the saved `playlistName` and track fingerprint (`tracks.map(\.id).joined(separator: "\n")`) match the current run, `RadioOrchestrator` asks the UI whether to reuse the saved scripts. Reuse restores `preGeneratedSegments` and still opens the review window before playback; decline archives the active saved session and regenerates. Normal show completion also archives the active cache so it is no longer offered for reuse. Manual stop and playback errors keep the active cache in place. The live store archives by renaming `pregenerated_session.json` to a timestamped JSON file in the same cache directory.

`RadioOrchestrator.applyEditedSegments(_:)` matches edited `ReviewScriptItem`s back to `preGeneratedSegments` by `segmentKey` (`SegmentKey.persistableKey`), not by array index — this stays correct even if a future editing feature reorders or filters the reviewed items before returning them.

The review handshake uses `CheckedContinuation<[ReviewScriptItem], Error>` — the actor suspends in `awaitScriptReview()` and resumes when `approveScripts(_:)` or `cancelReview()` is called. The reuse prompt uses `CheckedContinuation<Bool, Error>` and resumes through `confirmReuse()` / `declineReuse()`. `stopShow()` calls `failPendingContinuations()` to prevent continuation leaks. All resume paths nil-out their continuation before resuming to prevent double-resume crashes.

`ScriptGenerationMode` is a profile-scoped setting (`AppSettings.defaultScriptGenerationMode` / `ShowProfile.defaultScriptGenerationMode`), persisted the same way as `defaultOverlapMode`.

### BGM / jingle behavior

- TTS playback stays on `AudioPlaybackServiceProtocol.play(wavData:)`; BGM and jingles are controlled through `BedAudioPlaybackServiceProtocol`.
- Opening jingle and closing jingle are individually enabled. Transition narrations must not play jingles.
- A jingle asset is selected once during `prepareJingle`; duration estimation and playback must use that same prepared URL.
- Bed BGM is allowed only when no external music track is playing. Before starting a track, call `fadeOutAndStopBed(settings:)`.
- Bed fade operations are last-writer-wins through a generation token, and neither music nor bed fade progress advances while paused.
- In overlap mode, transition narration starts with bed disabled while the current track is still playing; after the track has fully stopped, start bed for the remaining narration if TTS is still active.
- If closing jingle is enabled while music is still playing, the orchestrator stops/fades the track before the jingle and closing narration.
- BGM / jingle failures should skip only that cue and must not fail TTS narration playback.

## Concurrency model

- `RadioOrchestrator` is a Swift `actor` — call its methods with `await` from `@MainActor` context in `MainViewModel`.
- `@MainActor` is required for all UI-touching code (`MainViewModel`, `AppSettingsStore`, views).
- All service protocols are `Sendable`.
- `MusicService.play(track:)` is expected to start the selected track from the beginning; the orchestrator does not seek back to `0` after calling it.

## Testing

`AgentBoothTests/TestDoubles.swift` contains fakes for all protocols (`FakeMusicService`, `FakeTTSService`, `FakeScriptGenerationService`, `ConditionalDelayTTSService`, `FakeServiceFactory`, etc.). Use these rather than mocking frameworks.

The script review window's logic is tested as plain `ObservableObject` behavior in `AgentBoothTests/ScriptReviewViewModelTests.swift`, independent of the SwiftUI view tree (XCTest cannot assert caret position). `testUpdateLineTextDoesNotPublishObjectWillChange` / `testUpdateSceneDirectionDoesNotPublishObjectWillChange` assert zero `objectWillChange` emissions from text-editing calls — this is the regression test for the caret-jumps-to-end bug and must not be removed or weakened.

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

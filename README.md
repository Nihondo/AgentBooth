# AgentBooth

AgentBooth は、Apple Music / YouTube Music / Spotify のプレイリストを素材にして AI ラジオ番組を自動進行する macOS 向けアプリです。  
現行の実装は `SwiftUI + Xcode project` ベースで、GUI からサービス・プレイリスト・オーバーラップモードを選んで番組を開始できます。

Python 実装は参照用コードとして、../AgentBooth_py/ にあり、プロンプト設計や従来フローの比較に使えます。  
新しい実行系は Swift 側です。

## 現在の実装範囲

- macOS 14+ 向け SwiftUI アプリを追加
- メイン画面に以下の操作を実装
  - サービス選択
  - プレイリスト選択
  - モード選択
  - `Start / Pause / Resume / Stop`
- 設定画面を実装
  - Gemini API Key は Keychain 保存
  - CLI / モデル / 音声 / パーソナリティ / 音量 / 番組情報は UserDefaults 保存
- `Apple Music` のプレイリスト取得と曲再生を AppleScript 経由で実装
- `YouTube Music` を WKWebView 内蔵ブラウザ経由で実装
  - 設定画面からログイン、Cookie による認証状態検出
  - 内部 API (`/youtubei/v1/browse`) を `SAPISIDHASH` 認証 + JS インジェクションで呼び出し
  - オフスクリーン NSWindow に配置した再生専用 WebView で常時オーディオ再生
- `Spotify` を WKWebView 内蔵ブラウザ経由で実装
  - 設定画面からログイン、DOM による認証状態検出
  - サイドバーとプレイヤー DOM をスクレイプしてプレイリスト取得・再生制御
  - オフスクリーン NSWindow に配置した再生専用 WebView で常時オーディオ再生
- `full_radio` を含む 5 種類のオーバーラップモードを Swift 側へ移植
- 台本生成を外部 CLI (`claude` / `gemini` / `codex` / `copilot`) 呼び出しで実装
- 台本生成結果は `dialogues` と `summaryBullets` を含む JSON を受け取り、後続プロンプトの重複回避に利用
- Gemini TTS を Swift から REST API で直接呼び出す実装を追加
- 生成した台本ログを `Application Support/AgentBooth/logs/scripts/` に保存
- `RadioOrchestrator` と `MainViewModel` の分離、ユニットテストを追加

## 制約事項

- 外部 CLI はユーザー環境にインストール済みである必要があります
- Mac App Store 配布前提の sandbox 対応はまだ行っていません
- Apple Music 制御には macOS の Automation 許可が必要です
- YouTube Music 利用には設定画面からの手動ログインが必要です
- Spotify 利用には設定画面からの手動ログインが必要です
- Spotify は DOM 制御のため、Spotify Web Player の UI 変更で取得や再生が失敗する場合があります

## 動作環境

- macOS 14 以降
- Xcode 17 系
- `xcodegen`
- Apple Music.app
- いずれかのスクリプト生成 CLI
  - `claude`
  - `gemini`
  - `codex`
  - `copilot`
- Gemini API Key

## セットアップ

### 1. プロジェクト生成

```bash
xcodegen generate
```

これで [AgentBooth.xcodeproj](/Users/nihondo/Library/CloudStorage/Dropbox/Projects.localized/AgentBooth/AgentBooth.xcodeproj) が生成されます。

### 2. Xcode で開く

```bash
open AgentBooth.xcodeproj
```

### 3. テスト実行

```bash
xcodebuild -project AgentBooth.xcodeproj -scheme AgentBooth -destination 'platform=macOS' -derivedDataPath /tmp/AgentBoothDerived test
```

## 使い方

### Apple Music

1. アプリを起動
2. `Settings` で Gemini API Key と Script CLI を保存
3. メイン画面で `サービス: Apple Music` を選択
4. `プレイリスト` を選択
5. `モード` を選択
6. `Start` で番組開始

### YouTube Music

1. `Settings` → `音楽` タブで `YouTube Music でログイン` をタップ
2. 表示される内蔵ブラウザで YouTube Music にログイン
3. ログイン成功後、インジケーターが緑に変わる
4. ウィンドウを閉じ、メイン画面で `サービス: YouTube Music` を選択
5. プレイリスト・モードを選択して `Start`

### Spotify

1. `Settings` → `音楽` タブで `Spotify でログイン` をタップ
2. 表示される内蔵ブラウザで Spotify にログイン
3. ログイン成功後、インジケーターが緑に変わる
4. ウィンドウを閉じ、メイン画面で `サービス: Spotify` を選択
5. プレイリスト・モードを選択して `Start`

### 共通

- 再生中は主ボタンが `Pause` に切り替わる
- 一時停止中は `Resume` に切り替わる
- `Stop` で停止すると主ボタンは `Start` に戻る

## オーバーラップモード

| モード | 説明 |
|---|---|
| `sequential` | 会話と楽曲を完全に直列で再生 |
| `outro_over` | 曲終盤フェードにトークを重ねる |
| `intro_over` | 曲開始後 `speakAfterSeconds` 秒でイントロトークを重ねる |
| `full_radio` | イントロ重ね、アウトロ重ね、ダッキングを組み合わせる |

## 設定項目

設定画面で主に次を扱います。

- `Gemini API Key`
- `TTS Model`
- `Fallback Model`
- `Script CLI`
- `CLI Model`
- `Male/Female Voice`
- `Male/Female Host`
- `Default Service`
- `Default Mode`
- `Normal Volume`
- `Talk Volume`
- `Fade Duration`
- `Fade Early Seconds`
- `Music Lead Seconds`
- `Show Name`
- `Frequency`

## ディレクトリ構成

```text
AgentBooth/
├── AgentBooth/                     # Swift app source
│   ├── App/                        # エントリポイント・DI
│   ├── Domain/                     # Protocols.swift, Models.swift
│   ├── Features/
│   │   ├── Main/                   # ContentView, MainViewModel
│   │   ├── Settings/               # SettingsView
│   │   ├── SpotifyBrowser/         # Spotify ログインブラウザ UI
│   │   └── YouTubeMusicBrowser/    # ログインブラウザ UI
│   ├── Infrastructure/
│   │   ├── Settings/               # AppSettingsStore
│   │   ├── Music/                  # AppleScriptExecutor
│   │   ├── Spotify/                # DOMScripts, ScriptRunner
│   │   └── YouTube/                # JSScripts, ScriptRunner
│   └── Services/
│       ├── Radio/                  # RadioOrchestrator
│       ├── Script/                 # ProcessScriptGenerationService
│       ├── TTS/                    # GeminiTTSService
│       ├── Audio/                  # SystemAudioPlaybackService
│       ├── Recording/
│       └── Music/                  # AppleMusicService, YouTubeMusicService, SpotifyMusicService
├── AgentBoothTests/                # Swift tests + TestDoubles
├── AgentBooth.xcodeproj/           # xcodegen 生成物
├── project.yml                     # XcodeGen 定義
├── main.py                         # 旧 Python CLI エントリ
├── orchestrator.py                 # 旧 Python フロー実装
├── music/                          # 旧 Python music 層
├── script/                         # 旧 Python script 層
├── tts/                            # 旧 Python tts 層
└── handoff.md
```

## 実装アーキテクチャ

- `MainViewModel`
  - UI 状態と各 picker / ボタンの操作を担当
- `RadioOrchestrator`
  - 番組進行、フェーズ遷移、音楽と TTS の協調制御を担当
- `MusicService` プロトコル
  - `AppleMusicService` — AppleScript 経由で Music.app を制御
  - `YouTubeMusicService` — WKWebView 経由で YouTube Music を制御
  - `SpotifyMusicService` — WKWebView 経由で Spotify Web Player を DOM 制御
- `YouTubeMusicWebViewStore`
  - ログイン UI 用 `webView` と再生専用 `playbackWebView` の 2 つを管理
  - 両者は `WKWebsiteDataStore.default()` を共有し Cookie を自動同期
  - `playbackWebView` はオフスクリーン `NSWindow` に配置してオーディオ再生を常時有効化
- `SpotifyWebViewStore`
  - ログイン UI 用 `webView` と再生専用 `playbackWebView` の 2 つを管理
  - 両者は `WKWebsiteDataStore.default()` を共有し Spotify セッションを自動同期
  - `playbackWebView` はオフスクリーン `NSWindow` に配置してオーディオ再生を常時有効化
- `YouTubeMusicAPIFetcher`
  - YouTube Music 内部 API (`/youtubei/v1/browse`) を WebView 内 JS で呼び出し
  - `SAPISIDHASH` 認証ヘッダーを `__Secure-3PAPISID` Cookie から `crypto.subtle.digest("SHA-1")` で計算
- `YouTubeMusicPlayerController`
  - `document.querySelector('video')` への JS 操作で再生・停止・音量制御
- `SpotifyDOMScripts`
  - Spotify サイドバー、トラックリスト、プレイヤー DOM を抽出・操作
  - 公式 API は使わず `open.spotify.com` 上の JS 挿入だけでプレイリスト取得と再生制御を行う
- `ProcessScriptGenerationService`
  - 外部 CLI による台本生成と `summaryBullets` の後方互換パース
- `GeminiTTSService`
  - Gemini REST API 呼び出しと WAV 生成
- `SystemAudioPlaybackService`
  - AVAudioPlayer ベースの TTS 再生
- `AppSettingsStore`
  - UserDefaults / Keychain の永続化

## 台本生成 JSON 形式

台本生成 CLI には、会話本文に加えて次回プロンプトで使う簡易サマリーも返させます。

```json
{
  "dialogues": [
    { "speaker": "male", "text": "発話内容" },
    { "speaker": "female", "text": "発話内容" }
  ],
  "summaryBullets": [
    "今回触れた話題の要点",
    "次回は避けたい観点"
  ]
}
```

- `summaryBullets` は 2〜4 件の短い箇条書きが想定です
- `RadioOrchestrator` は同一アーティスト / 同一アルバム時のみ、この箇条書きを次回プロンプトへ渡します
- 旧形式の `dialogues` のみ JSON も後方互換で受理し、その場合は会話先頭の抜粋をフォールバック要約として使います

## 将来予定

- エラーメッセージとセッション状態の UI 強化
- App Sandbox / 配布設定の整備
- Python 実装との差分整理と不要コードの段階的縮退

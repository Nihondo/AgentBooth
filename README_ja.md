# AgentBooth

Apple Music / YouTube Music / Spotify のプレイリストを素材に、AI が自動進行するラジオ番組を流す macOS アプリです。

AI が台本を作り、2 人のパーソナリティが読み上げ、音楽と重ねて再生します。

---

## 動作環境

- macOS 14 (Sonoma) 以降
- 台本生成に使う AI CLI（いずれか 1 つをインストールしておきます）
  - `claude`（Claude Code）
  - `gemini`
  - `codex`（ChatGPT Codex）
  - `copilot`
- Gemini API Key（読み上げに使用。[Google AI Studio](https://aistudio.google.com/) で無料取得可能です）

---

## クイックスタート

1. アプリを起動する（初回は右クリック → **開く**）
2. **設定** → **テキスト読み上げ** タブを開く
3. **API Key** に Gemini API Key を入力する（[Google AI Studio](https://aistudio.google.com/) で無料取得可能です）
4. **CLI** で台本生成に使う AI を選ぶ（例: `claude`）
5. 設定を閉じ、メイン画面でプレイリストを選んで **Start**

Apple Music はこれだけで動作します。YouTube Music / Spotify は先にログインが必要です（→ [使い方](#使い方)）。

![](images/agentbooth_main.png)

> プレイリストからのトラック取得は最大 30 曲までに制限しています

---

## 設定ガイド

アプリを起動したら、ツールバーの **設定** ボタンを開いて各タブを設定します。

### テキスト読み上げ

最初に設定するタブ。API Key と CLI が未設定だと番組を開始できません。

| 項目 | 説明 |
|---|---|
| **API Key** | Google AI Studio で取得した Gemini API Key を入力する(**必須**) |
| **TTS モデル** | 読み上げに使う Gemini モデル（既定値のままで動作します） |
| **フォールバックモデル** | 主モデルが失敗したときの予備モデル |
| **男性ボイス** | 男性パーソナリティの声（例: `Charon`） |
| **女性ボイス** | 女性パーソナリティの声（例: `Kore`） |
| **CLI** | 台本生成に使う AI CLI を選ぶ（`claude` / `gemini` / `codex` / `copilot`）(**必須**) |
| **CLI モデル** | CLI で使うモデル名（空欄にするとその CLI の既定値を使う） |

### サービス

| 項目 | 説明 |
|---|---|
| **既定のサービス** | 起動時にデフォルトで選ばれる音楽サービス |
| **YouTube Music でログイン** | YouTube Music を使う場合にここからログインします |
| **Spotify でログイン** | Spotify を使う場合にここからログインします |

### 番組情報

| 項目 | 説明 |
|---|---|
| **オーバーラップモード** | 音楽とトークの重ね方（後述） |
| **番組名** | 台本に反映される番組名 |
| **周波数・チャンネル名** | 例: `77.5 FM`（台本の雰囲気づけに使う） |
| **男性ホスト名** | 男性パーソナリティの名前 |
| **女性ホスト名** | 女性パーソナリティの名前 |
| **シーン・セリフの指示** | 台本生成への追加指示（例: 深夜帯、静かに話す） |

### 楽曲の再生

音楽とトークのバランス調整。既定値のままでも動作します。

| 項目 | 説明 |
|---|---|
| **通常音量** | 音楽の基準音量（0〜100） |
| **トーク時音量** | トーク中に下げる音量（0〜100）。小さいほど音楽が小さくなる |
| **フェード秒数** | 音量を滑らかに変える時間（秒） |
| **楽曲先行開始秒数** | トーク終了前に次の曲を重ねて流し始める秒数 |
| **曲開始後のトーク開始秒数** | 曲が始まってからトークを重ねるまでの秒数 |
| **曲終了前のトーク再開秒数** | 曲が終わる何秒前からトークを開始するか |
| **楽曲最大再生秒数** | 1 曲あたりの上限時間（0 で無制限） |

### 録音

番組を録音したい場合に設定します。

| 項目 | 説明 |
|---|---|
| **録音出力先** | 録音ファイルの保存先フォルダ。空欄なら `~/Music/AgentBooth/` に保存されます |

> 録音はシステム音声全体を収録します。初回録音時に「画面収録」の権限確認が表示されます。
> システム通知や他のアプリの音も録音されるため、録音中は通知をオフにすることをおすすめします。
---

## 使い方

### 共通

1. **テキスト読み上げ**タブで API Key と CLI を設定する

### Apple Music

1. メイン画面でサービスに **Apple Music** を選ぶ
2. プレイリストを選ぶ
3. **Start** で番組開始

> 初回起動時に「自動化」の許可を求めるダイアログが表示されます。**許可** を選んでください。

### YouTube Music

1. **サービス**タブ → **YouTube Music でログイン** を押す
2. 表示された内蔵ブラウザで YouTube Music にログインする
3. ログイン成功後、ログイン状態が **ログイン済み**（緑）に変わる
4. ウィンドウを閉じて、メイン画面でサービスに **YouTube Music** を選ぶ
5. プレイリストを選んで **Start**

### Spotify

1. **サービス**タブ → **Spotify でログイン** を押す
2. 表示された内蔵ブラウザで Spotify にログインする
3. ログイン状態が **ログイン済み**（緑）に変わる
4. ウィンドウを閉じて、メイン画面でサービスに **Spotify** を選ぶ
5. プレイリストを選んで **Start**

---

## 操作

| ボタン | 動作 |
|---|---|
| **Start** | 番組開始 |
| **Pause** | 一時停止（再生中に表示） |
| **Resume** | 再開（一時停止中に表示） |
| **Stop** | 停止して最初に戻る |

画面下部の **NowPlayingBar** に現在のトラック（アートワーク付き）と番組の進行状態が表示されます。

---

## 再生モード

番組情報タブの **オーバーラップモード** で選択できます。

| モード | 動作 |
|---|---|
| **ラジオ風に自然に重ねる** | 曲の始まりと終わりにトークを自然に重ねる。FMラジオに近い聴こえ方 |
| **曲の開始後にトークを重ねる** | 曲が始まってしばらくしたら、演奏中にトークを重ねる |
| **曲の終了前にトークを重ねる** | 曲が終わりに近づいたらフェードしながら次のトークを始める |
| **曲とトークを完全に分ける** | 曲が終わってからトーク、トークが終わってから次の曲（重ねなし） |

---

## トラブルシューティング

### プレイリストが途中で切れている

プレイリストから取得する曲数の上限は 30 曲に設定しています。多い曲数のプレイリストを選んだ場合、最初の 30 曲のみが使用されます。

### Apple Music のプレイリストが取得できない

システム設定 → プライバシーとセキュリティ → 自動化 を開き、**AgentBooth** の項目に **Music** の許可が入っているか確認してください。

### YouTube Music / Spotify のログイン状態が「未ログイン」のまま

- 内蔵ブラウザでログインを完了してからウィンドウを閉じ、再度設定タブを開いて確認してください
- ログインが途中で詰まる場合は **データを削除** を押してサイトデータを消去してから再ログインしてください

### Spotify でプレイリストが取得できない・再生が止まる

Spotify Web Player の画面構造が変わると動作しなくなることがあります。

### 台本生成が始まらない・エラーになる

- **テキスト読み上げ**タブで選んだ CLI（`claude` など）がインストール済みか確認してください
- CLI のインストール先によってはアプリから見つからない場合がある。その場合はフルパス（例: `/usr/local/bin/claude`）で CLI モデル欄に入力するか、インストール場所を確認してください

### 音声（読み上げ）が生成されない

- **テキスト読み上げ**タブで Gemini **API Key** が正しく設定されているか確認してください
- API Key の残量や有効期限を Google AI Studio で確認してください

---

## 開発者向け情報

### アーキテクチャ概要

```
Domain/           プロトコルと全バリュー型（Protocols.swift / Models.swift）
App/              エントリポイント・DI（AppServiceContainer）
Features/         UI 層（ContentView / MainViewModel / SettingsView / NowPlayingBar）
Services/         ビジネスロジック（Radio / Script / TTS / Music / Audio）
Infrastructure/   外部依存ラッパー（AppleScript / WebView / Settings）
AgentBoothTests/  ユニットテスト + フェイク実装（TestDoubles.swift）
```

### 主要コンポーネント

**`RadioOrchestrator`** (`Services/Radio/`) — Swift `actor`。番組進行の中核。opening → intro → playing → transition/outro → closing のフェーズを駆動し、音楽・TTS・フェードを協調制御する。

**`MainViewModel`** (`Features/Main/`) — `@MainActor ObservableObject`。`RadioOrchestrator` を保持し、UI 状態 (`RadioState`) を SwiftUI ビューへブリッジする。

**`ProcessScriptGenerationService`** (`Services/Script/`) — 外部 CLI サブプロセスを呼び出して JSON 台本を生成する。

**`GeminiTTSService`** (`Services/TTS/`) — Gemini REST API を直接呼び出して WAV を生成する。リトライ・フォールバックモデルあり。

**`AppleMusicService`** (`Services/Music/`) — `AppleScriptExecutor` 経由で Music.app を制御する。

**`YouTubeMusicService`** (`Services/Music/`) — `@MainActor`。`YouTubeMusicAPIFetcher`（内部 API 呼び出し）と `YouTubeMusicPlayerController`（再生制御）に委譲する。

**`SpotifyMusicService`** (`Services/Music/`) — `@MainActor`。`open.spotify.com` の DOM をスクレイプしてプレイリスト取得・再生制御を行う。

**`YouTubeMusicWebViewStore`** / **`SpotifyWebViewStore`** — ログイン UI 用 WebView と再生専用 WebView（オフスクリーン `NSWindow`）の 2 本を管理する。`WKWebsiteDataStore.default()` を共有して Cookie を自動同期する。

### ディレクトリ構成

```
AgentBooth/
├── AgentBooth/
│   ├── App/                        エントリポイント・DI
│   ├── Domain/                     Protocols.swift, Models.swift
│   ├── Features/
│   │   ├── Main/                   ContentView, MainViewModel, NowPlayingBar
│   │   ├── Settings/               SettingsView
│   │   ├── SpotifyBrowser/         Spotify ログインブラウザ UI
│   │   └── YouTubeMusicBrowser/    YouTube Music ログインブラウザ UI
│   ├── Infrastructure/
│   │   ├── Settings/               AppSettingsStore
│   │   ├── Music/                  AppleScriptExecutor, AppleMusicArtworkFetcher
│   │   ├── Spotify/                SpotifyDOMScripts, SpotifyScriptRunner
│   │   └── YouTube/                YouTubeMusicJSScripts, YouTubeMusicScriptRunner
│   └── Services/
│       ├── Radio/                  RadioOrchestrator
│       ├── Script/                 ProcessScriptGenerationService
│       ├── TTS/                    GeminiTTSService
│       ├── Audio/                  SystemAudioPlaybackService
│       ├── Recording/
│       └── Music/                  AppleMusicService, YouTubeMusicService, SpotifyMusicService
├── AgentBoothTests/                ユニットテスト + TestDoubles.swift
├── project.yml                     XcodeGen 定義
└── handoff.md
```

### 台本生成 JSON 形式

CLI は以下の JSON を stdout に出力する必要がある。

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

- `summaryBullets`: 2〜4 件の短い箇条書き
- 同一アーティスト / 同一アルバム時のみ、次回プロンプトへ渡す
- `dialogues` のみの旧形式も後方互換で受理する

### ビルド・テスト

```bash
# プロジェクト生成
xcodegen generate

# 全テスト
xcodebuild -project AgentBooth.xcodeproj -scheme AgentBooth \
  -destination 'platform=macOS' -derivedDataPath /tmp/AgentBoothDerived test

# 特定テストクラスのみ
xcodebuild -project AgentBooth.xcodeproj -scheme AgentBooth \
  -destination 'platform=macOS' -derivedDataPath /tmp/AgentBoothDerived test \
  -only-testing:AgentBoothTests/RadioOrchestratorTests
```

### 制約・注意事項

- App Sandbox 無効（`ENABLE_APP_SANDBOX: NO`） — Mac App Store 配布未対応
- `project.yml` を編集 → `xcodegen generate` でプロジェクト再生成する（`.xcodeproj` は直接編集しない）
- 外部 CLI はアプリのプロセス環境から解決する（シェルの `$PATH` と異なる場合がある）
- Spotify 連携は DOM 制御のため、Spotify Web Player UI 変更でセレクターが壊れる可能性あり

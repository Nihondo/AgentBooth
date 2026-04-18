# AgentBooth 番組フロー

## 概要

現行実装は「常に 1 本の再生中ナレーションを持ち、そのナレーションに合わせて曲を始める」構造になっている。

```text
[開始]
  → オープニング生成・TTS
  → オープニング再生
  → 曲1
  → トランジション生成・TTS
  → 曲2
  → ...
  → クロージング生成・TTS
  → クロージング再生
  → [終了]
```

重要な点:

- `intro_over` は廃止
- オーバーラップ設定は `enabled` / `disabled` の 2 値
- TTS は締切でスキップしない
- 早期終了位置に達しても、次 TTS が未完成なら現在曲を自然終端まで延長する
- 同じ TTS を二重再生しないため、ループをまたいで持つのは「音声データ」ではなく「再生中ハンドル」

---

## 1. 起動・初期化

| 処理 | 詳細 |
|---|---|
| `startShow()` | ユーザーが開始ボタンを押す |
| 状態初期化 | `isRunning=true`, `isPaused=false`, `phase=idle` |
| `loadTracks()` | 選択中サービスからプレイリストの曲一覧を取得 |
| 状態更新 | `upcomingTracks`, `playlistTrackCount`, `phase=opening` を更新 |

---

## 2. オープニング準備

オープニングだけは同期処理。

```text
CLI で opening スクリプト生成
  → Gemini TTS で音声合成
  → PreparedNarration 完成
  → `rememberTopics()` で summaryBullets を履歴に記録
  → 録音開始（有効時）
  → `startNarration()` で再生開始
```

ここで作られた再生中ハンドルが、最初の `activeNarration` になる。

---

## 3. ループ中の状態モデル

現行実装は各ループで次の 2 つを使う。

| 状態 | 意味 |
|---|---|
| `activeNarration` | すでに再生開始済みのナレーション |
| `nextNarrationTask` | 曲再生中にバックグラウンドで進む次ナレーション生成タスク |

`activeNarration` の中身:

```swift
PreparedNarration
+ playbackTask
+ durationSeconds
```

これにより、

- 曲末で始めたトランジション/クロージングを次ループでもう一度 `play` しない
- 次曲開始タイミングを「再生中 TTS の残り時間」で決められる

---

## 4. 曲ループ

各曲について同じ流れで進む。

### 4-1. 曲開始前

```text
updateTrackState()
phase = intro
currentTrack / trackIndex / currentPlaybackPosition を更新
```

### 4-2. 再生中ナレーションに合わせて曲開始

#### オーバーラップあり (`OverlapMode.enabled`)

```text
activeNarration の残り時間が `musicLeadSeconds` 以下になるまで待つ
  → 曲を `talkVolume` で開始
  → TTS 完了後、`fadeDuration` で `normalVolume` まで戻す
```

#### オーバーラップなし (`OverlapMode.disabled`)

```text
activeNarration の再生完了まで待つ
  → 曲を `normalVolume` で開始
```

どちらの場合も、曲再生開始時に:

- `musicService.play(track:)`
- `seekToPosition(0)`
- `trackStartedAt` を記録
- `startPositionPolling()` を開始

---

### 4-3. 次ナレーションの先読み

曲開始後すぐに、次のナレーション生成をバックグラウンドで始める。

#### 次の曲がある場合

```text
CLI で transition スクリプト生成
  → Gemini TTS で音声合成
```

- プロンプトは「前曲感想 + 次曲紹介」
- `buildContinuityNote()` が同一アーティスト/アルバム時の既出話題を渡す

#### 最終曲の場合

```text
CLI で closing スクリプト生成
  → Gemini TTS で音声合成
```

---

### 4-4. 通常のアウトロ開始点まで進める

```text
phase = playing
waitUntilOutroPoint(track)
phase = outro
```

`waitUntilOutroPoint()` は再生位置をポーリングし、

```text
targetPosition = effectivePlaybackDuration - fadeEarlySeconds
```

に達したら復帰する。

`effectivePlaybackDuration` は:

```text
maxPlaybackDurationSeconds == 0
  ? 曲の長さ
  : min(曲の長さ, maxPlaybackDurationSeconds)
```

再生位置が取れない場合は `trackStartedAt` からの経過時間でフォールバックする。

---

### 4-5. 次 TTS を待つ

現行実装では、アウトロ開始点に達しても `nextNarrationTask` が未完ならスキップしない。

```text
resolveNextNarration()
  → まず「次 TTS 完了」か「現在曲の自然終端」まで待つ
  → 自然終端に先に達したら曲を止める
  → その後も task.value を await して完成を待つ
```

この待ち合わせにより:

- 早期終了位置に来たからといってトランジションを捨てない
- `maxPlaybackDurationSeconds` を超えても、自然終端までは流し続けられる
- 自然終端後は無音待ちになることがある

---

### 4-6. 次ナレーション開始と現トラック停止

#### オーバーラップあり

現在曲がまだ鳴っている場合:

```text
音量を `talkVolume` まで下げる
  → 次ナレーションを開始 (`startNarration`)
  → 現在曲をフェードアウトして停止
```

停止後、今始めたナレーションが次ループの `activeNarration` になる。

#### オーバーラップなし

```text
現在曲を停止
  → 次ナレーションを開始 (`startNarration`)
```

---

## 5. クロージング

最終ループでは `nextNarrationTask` が closing を返す。

```text
phase = closing
closing の再生を開始
  → playbackTask 完了まで待つ
```

closing もトランジションと同じ仕組みで生成されるが、
最終ループのため次曲開始は行わない。

---

## 6. 終了処理

```text
audioPlaybackService.stopPlayback()
musicService.stopPlayback()
録音停止・保存
resetState()
```

`resetState()` では:

- `isRunning = false`
- `isPaused = false`
- `phase = idle`
- `currentTrack = nil`
- `upcomingTracks = []`
- `currentPlaybackPosition = 0`

などを初期化する。

---

## 7. 一時停止・再開

`pauseShow()` / `resumeShow()` は音楽と音声再生を両方止める。

### 一時停止

```text
isPaused = true
musicService.pausePlayback()
audioPlaybackService.pausePlayback()
```

### 再開

```text
isPaused = false
musicService.resumePlayback()
audioPlaybackService.resumePlayback()
```

`waitRespectingPause()` を使う箇所は、一時停止中に進行しない。

- ナレーション残り時間待ち
- アウトロ位置待ち
- TTS 遅延時のポーリング待ち
- フェード中のスリープ

---

## フェーズ遷移

```text
idle
 │
 ▼
opening
 │  オープニング生成・TTS・録音開始
 ▼
intro
 │  activeNarration に合わせて曲開始
 ▼
playing
 │  曲再生 + 次ナレーション生成
 ▼
outro
 │  次ナレーション待ち + 必要なら曲延長
 │
 ├─ 次曲あり → intro（次曲）
 └─ 最終曲   → closing
               │
               ▼
              idle
```

---

## 並行処理の依存関係

```text
曲再生中
│
├─ [メイン] activeNarration の完了待ち・音量制御
│
├─ [バックグラウンド] nextNarrationTask
│   ├─ transition スクリプト生成 または closing スクリプト生成
│   └─ TTS 音声合成
│
└─ [バックグラウンド] 再生位置ポーリング
    └─ `currentPlaybackPosition` を定期更新
```

以前の `TimedPreparation` / `intro_over` 専用経路は現行実装には存在しない。

---

## 重要な設定値（`VolumeSettings`）

| 設定 | デフォルト | 説明 |
|---|---|---|
| `normalVolume` | 100 | 通常の音楽音量 |
| `talkVolume` | 25 | トーク中の音楽音量 |
| `fadeDuration` | 5.0s | 音量を滑らかに変える時間 |
| `fadeEarlySeconds` | 10s | 実効終端の何秒前からアウトロへ入るか |
| `musicLeadSeconds` | 10.0s | ナレーション終了前に次曲を出し始める秒数 |
| `maxPlaybackDurationSeconds` | 0 | 1曲あたりの実効再生上限。0 は無制限 |

---

## タイムライン

### オーバーラップあり

```text
ナレーション再生
|-------------------------------|
                         ^ 残り `musicLeadSeconds`
                         |
曲再生開始               |
|===============================|

曲終端側
                  ^ アウトロ開始（実効終端 - fadeEarlySeconds）
                  |---- 次 TTS 完成待ち ----|
                  | TTS 完成後は talkVolume に下げて重ねる |
```

### オーバーラップなし

```text
ナレーション
|-----------|
            曲
            |================|
                            次ナレーション
                            |-----------|
```

### TTS 遅延時の曲延長

```text
実効終端                    自然終端
|---------------------------|----------------|
                次 TTS 未完
                → 曲は自然終端まで継続
                                   次 TTS まだ未完なら無音待ち
```

---

## トピック重複回避

同一アーティスト・同一アルバムが続く場合、
`summaryBullets` を `artistTopicHistory` / `albumTopicHistory` に保持し、
次の transition prompt へ continuity note として渡す。

ルール:

- 1 キーあたり最大 2 件保持
- 重複項目は追加しない
- `summaryBullets` が空なら会話文の先頭数行からフォールバック要約を作る

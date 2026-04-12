# AgentBooth 番組フロー

## 概要

```
[開始] → オープニング → 曲1 → トランジション → 曲2 → ... → クロージング → [終了]
```

---

## 1. 起動・初期化

| 処理 | 詳細 |
|------|------|
| `startShow()` 呼び出し | ユーザーが「開始」ボタンを押す |
| 状態初期化 | `isRunning=true`, `phase=idle` |
| `loadTracks()` | Apple Music から指定プレイリストの曲一覧を取得 |
| 状態更新 | `upcomingTracks` にセット、`phase=opening` |

---

## 2. オープニング準備

**同期処理（曲再生前にブロック）**

```
CLI でスクリプト生成（opening）
  → Gemini TTS で音声合成（WAV）
  → preparedOpeningNarration 完成
  → 録音開始（isRecordingEnabled=true の場合）
```

- プロンプト: 番組挨拶 + プレイリスト紹介 + 1曲目への導入（6〜10ターン）
- `summaryBullets` を `artistTopicHistory` / `albumTopicHistory` に記録

---

## 3. 曲ループ（全曲分繰り返し）

### 3-1. 最終曲の検出でクロージング準備を開始

最終トラックの処理開始直後、バックグラウンドで非同期に開始：

```
CLI でスクリプト生成（closing）
  → Gemini TTS で音声合成
```

### 3-2. トラック開始指示の決定

| 条件 | 指示 |
|------|------|
| 1曲目 | オープニングナレーションを再生 |
| 前のアウトロでトランジション済み | トラック再生済みとしてスキップ |
| イントロ事前準備が完了済み | イントロナレーションを再生 |
| 上記以外 | ナレーションなしで曲のみ開始 |

### 3-3. イントロ再生（`playIntroIfNeeded`）

`overlapMode` に応じて動作が異なる：

| モード | 動作 |
|--------|------|
| `sequential` | ナレーション再生 → 曲開始（完全分離） |
| `outro_over` | ナレーション再生 → 曲開始（完全分離） |
| `intro_over` / `full_radio` | ナレーション再生と同時に、終了 `musicLeadSeconds` 秒前に曲を低音量で開始 |
| `music_bed` | ナレーション再生 → 曲開始（完全分離） |

### 3-4. 曲再生中

```
phase = playing
音楽再生（Apple Music）
並行してトランジションスクリプトを非同期生成
  → CLI でスクリプト生成（transition: 前曲感想 + 次曲紹介）
  → Gemini TTS で音声合成
```

`calculateWaitBeforeTransition()` で待機秒数を算出：

```
待機秒数 = 曲の実効再生時間 − fadeEarlySeconds − 経過秒数
```

※ `maxPlaybackDurationSeconds > 0` の場合、曲の長さを打ち切り

### 3-5. アウトロ処理（`handleTrackEnding`）

#### 次の曲がある場合（トランジション）

```
トランジション準備が完了済みか確認
  ├─ 完了 → フェードアウト → 曲停止 → トランジションナレーション再生
  │          並行: ナレーション終了 musicLeadSeconds 前に次曲を低音量で開始
  │          → 次曲の音量をフェードイン（normalVolume まで）
  │          → outcome = startedNextTrackViaTransition
  └─ 未完了/失敗 → フェードアウト → 曲停止
                   → outcome = finishedCurrentTrackOnly
```

#### 最終曲の場合

```
フェードアウト → 曲停止
→ outcome = finishedFinalTrack
```

---

## 4. クロージング

```
phase = closing
クロージング準備の完了を待機（バックグラウンドで既に開始済み）
  ├─ 完了済み → 即座に再生
  └─ 未完了   → 生成完了まで待機してから再生
ナレーション再生（今日の振り返り + リスナーへの感謝 + 次回予告）
```

---

## 5. 終了処理

```
audioPlaybackService.stopPlayback()
musicService.stopPlayback()
録音停止・ファイル保存（isRecordingEnabled=true の場合）
状態リセット（isRunning=false, phase=idle）
```

---

## フェーズ遷移図

```
idle
 │
 ▼
opening（オープニングスクリプト生成・TTS）
 │
 ▼
intro（1曲目イントロナレーション再生）
 │
 ▼
playing（曲再生 ＋ トランジション非同期準備）
 │
 ▼
outro（フェードアウト・トランジション再生）
 │                    │
 │ 次曲あり           │ 最終曲
 ▼                    ▼
intro（次曲）        closing（クロージング再生）
 ...                  │
                       ▼
                      idle（終了）
```

---

## 並行処理の依存関係

```
曲再生中（playing フェーズ）
│
├─ [バックグラウンド] トランジションスクリプト生成
│   └─ TTS 音声合成
│       └─ アウトロポイントで結果を参照
│
└─ [バックグラウンド] ※最終曲のみ：クロージングスクリプト生成
    └─ TTS 音声合成
        └─ 全曲終了後に結果を参照
```

---

## 重要な設定値（`VolumeSettings`）

| 設定 | デフォルト | 説明 |
|------|-----------|------|
| `normalVolume` | 100 | 通常の音楽音量 |
| `talkVolume` | 25 | トーク中の音楽音量 |
| `fadeDuration` | 5.0s | フェード時間 |
| `fadeEarlySeconds` | 10s | アウトロポイントの早出し秒数 |
| `musicLeadSeconds` | 10.0s | ナレーション終了前に音楽を開始する秒数 |
| `maxPlaybackDurationSeconds` | 0（無制限） | 1曲あたりの最大再生秒数 |

---

## トピック重複回避

同一アーティスト・アルバムが続く場合、`summaryBullets` をもとに既出トピックを次のプロンプトに渡す。最大2件を保持し、古いものから順に破棄。

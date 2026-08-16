import Foundation

/// 発音辞書クイック登録の入力エラー。
enum PronunciationRegistrationError: LocalizedError {
    case emptySourceOrReading

    var errorDescription: String? {
        String(localized: "表記と読みの両方を入力してください。")
    }
}

/// セグメント単位の TTS 試聴の状態。
enum SegmentPreviewState: Equatable, Sendable {
    case idle
    /// API 呼び出し中。
    case synthesizing
    /// 再生中。
    case playing
    /// 直近の合成結果をキャッシュ済み（次回はテキストが変わっていなければ API を叩かず再生のみ）。
    case ready
    case failed(String)
}

/// 行単位の TTS 試聴で確認待ちになっている対象。
struct LinePreviewRequest: Equatable, Sendable {
    let segmentID: UUID
    let lineID: UUID
}

/// 検索ナビゲーションによるフォーカス移動リクエスト。`ScriptReviewSegmentEditor` がこれを observe し、
/// 対象セグメント表示中であれば `@FocusState` を該当エディタへ移す。
struct FocusRequest: Equatable {
    let segmentID: UUID
    let target: ReviewMatch.Target
    let token: Int
}

/// 台本事前生成レビュー画面のためのドラフト状態を保持する ViewModel。
///
/// ## キャレット保護の設計契約（崩さないこと）
/// `segments` は意図的に `@Published` ではない。ここへ 1 文字ごとに書き込むたびに
/// `objectWillChange` を送ると、レビューウィンドウ内の全 `TextEditor` / `TextField` が
/// 再構築され、NSTextView への文字列再代入によってキャレットが末尾へ飛ぶ不具合が起きる
/// （旧 `ScriptReviewView` で発生していた不具合そのもの）。
///
/// - テキスト編集（`updateLineText` / `updateSceneDirection`）は `segments` を直接書き換えるのみで、
///   `objectWillChange` を発火しない。
/// - 行の追加・削除・並べ替え・話者切替・検索置換・undo など「構造」を変える操作だけが
///   `structureRevision` を +1 する。これが `ReviewSeedToken` に含まれ、対応する
///   `DraftTextEditor` だけが強制的に再シードされる。
/// - `contentRevision` はテキスト編集を 0.5 秒デバウンスして通知する専用チャンネルで、
///   ヒット件数や TTS 入力プレビューなど「打鍵に追従してよい派生 UI」だけが購読する。
///   `ReviewSeedToken` には含めないため、これが変化してもエディタは再シードされない。
@MainActor
final class ScriptReviewViewModel: ObservableObject {
    /// レビュー対象セグメントのドラフト。@Published にしない（上記契約を参照）。
    private(set) var segments: [ReviewSegmentDraft]

    /// 行構成・置換・undo でのみ +1。`DraftTextEditor` の再シードトリガ。
    @Published private(set) var structureRevision: Int = 0
    /// テキスト編集の 0.5 秒デバウンス通知。派生 UI 専用（打鍵ごとには上がらない）。
    @Published private(set) var contentRevision: Int = 0
    @Published var selectedSegmentID: ReviewSegmentDraft.ID?
    @Published var search = ReviewSearchState()
    /// 検索ナビゲーション（次へ/前へ）によるフォーカス移動リクエスト。
    /// `token` を毎回インクリメントすることで、同じ対象へ2回連続でジャンプしても `onChange` が確実に発火する。
    @Published private(set) var focusRequest: FocusRequest?
    /// セグメント単位の TTS 試聴状態。
    @Published private(set) var previewStates: [ReviewSegmentDraft.ID: SegmentPreviewState] = [:]
    /// 発話行単位の TTS 試聴状態。
    @Published private(set) var linePreviewStates: [ReviewLineDraft.ID: SegmentPreviewState] = [:]
    /// 「API を1回消費します」の確認待ちセグメント（nil なら確認ダイアログは非表示）。
    @Published var pendingPreviewConfirmationSegmentID: ReviewSegmentDraft.ID?
    /// 「API を1回消費します」の確認待ち発話行（nil なら確認ダイアログは非表示）。
    @Published private(set) var pendingLinePreviewConfirmation: LinePreviewRequest?

    private let settingsStore: AppSettingsStore
    private let serviceFactory: any AppServiceFactory
    private let isTestMode: Bool
    private var contentRevisionTask: Task<Void, Never>?

    /// 構造編集の undo スタック。深さ20で打ち切る。
    private var undoStack: [[ReviewSegmentDraft]] = []
    private let undoStackLimit = 20

    /// 「このセッションでは確認しない」が選ばれた後は true になり、以降は確認ダイアログを出さない。
    private var skipsPreviewConfirmation = false
    private enum PreviewTarget: Hashable, Sendable {
        case segment(ReviewSegmentDraft.ID)
        case line(ReviewLineDraft.ID)
    }

    /// 直近に合成した音声のキャッシュ。対象ごとの入力ハッシュが一致すれば API を叩かず再生のみ行う。
    private var previewCache: [PreviewTarget: (contentHash: Int, wavData: Data)] = [:]
    private var previewTask: Task<Void, Never>?
    private var activePreviewAudioService: (any AudioPlaybackServiceProtocol)?

    init(
        items: [ReviewScriptItem],
        settingsStore: AppSettingsStore,
        serviceFactory: any AppServiceFactory,
        isTestMode: Bool
    ) {
        self.segments = items.map { ReviewSegmentDraft(item: $0) }
        self.settingsStore = settingsStore
        self.serviceFactory = serviceFactory
        self.isTestMode = isTestMode
        self.selectedSegmentID = segments.first?.id
    }

    // MARK: - 参照

    func segment(withID id: ReviewSegmentDraft.ID) -> ReviewSegmentDraft? {
        segments.first { $0.id == id }
    }

    /// `DraftTextEditor` へ渡す再シード判定キー。`structureRevision` の変化にのみ追従する。
    func seedToken(for targetID: UUID) -> ReviewSeedToken {
        ReviewSeedToken(targetID: targetID, structureRevision: structureRevision)
    }

    var validationIssues: [ReviewValidationIssue] {
        var issues: [ReviewValidationIssue] = []
        for segment in segments {
            if segment.lines.isEmpty {
                issues.append(.emptySegment(segmentID: segment.id))
                continue
            }
            for line in segment.lines where line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyLine(segmentID: segment.id, lineID: line.id))
            }
        }
        return issues
    }

    // MARK: - テキスト編集（objectWillChange を発火しない）

    /// 発話指示（sceneDirection）を書き換える。無通知。
    func updateSceneDirection(segmentID: UUID, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].sceneDirection = text
        scheduleContentRevisionBump()
    }

    /// 発話行のテキストを書き換える。無通知。
    func updateLineText(segmentID: UUID, lineID: UUID, text: String) {
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
              let lineIndex = segments[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return }
        segments[segmentIndex].lines[lineIndex].text = text
        scheduleContentRevisionBump()
    }

    private func scheduleContentRevisionBump() {
        contentRevisionTask?.cancel()
        contentRevisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.contentRevision += 1
        }
    }

    // MARK: - 構造編集（行の追加・削除・並べ替え・話者切替）
    //
    // ここに属するメソッドはすべて `structureRevision` を +1 する。これにより
    // 対応する `DraftTextEditor` が `seedToken` の変化を検知して強制的に再シードされ、
    // 行の増減や並べ替えが画面へ反映される。1操作 = 1 undo ステップとして
    // `undoLastStructuralChange()` で巻き戻せる。

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndoSnapshot() {
        undoStack.append(segments)
        if undoStack.count > undoStackLimit {
            undoStack.removeFirst(undoStack.count - undoStackLimit)
        }
    }

    func undoLastStructuralChange() {
        guard let previous = undoStack.popLast() else { return }
        segments = previous
        structureRevision += 1
    }

    /// セグメント末尾に空の発話行を追加する。
    func appendLine(to segmentID: UUID, speaker: ReviewSpeaker) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        pushUndoSnapshot()
        segments[index].lines.append(ReviewLineDraft(speaker: speaker, text: ""))
        structureRevision += 1
    }

    /// 指定行の直後に空の発話行を挿入する。
    func insertLine(in segmentID: UUID, after lineID: UUID, speaker: ReviewSpeaker) {
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
              let lineIndex = segments[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return }
        pushUndoSnapshot()
        segments[segmentIndex].lines.insert(ReviewLineDraft(speaker: speaker, text: ""), at: lineIndex + 1)
        structureRevision += 1
    }

    /// 発話行を削除する。セグメント内の最後の1行は削除しない（TTS への空 transcript 送出を防ぐ）。
    func removeLine(_ lineID: UUID, in segmentID: UUID) {
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
              segments[segmentIndex].lines.count > 1,
              let lineIndex = segments[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return }
        pushUndoSnapshot()
        segments[segmentIndex].lines.remove(at: lineIndex)
        structureRevision += 1
    }

    /// 話者（男性⇄女性）を切り替える。
    func toggleSpeaker(of lineID: UUID, in segmentID: UUID) {
        setSpeaker(of: lineID, in: segmentID) { $0.toggled }
    }

    /// 話者を指定の値へ設定する。
    func setSpeaker(_ speaker: ReviewSpeaker, of lineID: UUID, in segmentID: UUID) {
        setSpeaker(of: lineID, in: segmentID) { _ in speaker }
    }

    private func setSpeaker(of lineID: UUID, in segmentID: UUID, transform: (ReviewSpeaker) -> ReviewSpeaker) {
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
              let lineIndex = segments[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return }
        pushUndoSnapshot()
        segments[segmentIndex].lines[lineIndex].speaker = transform(segments[segmentIndex].lines[lineIndex].speaker)
        structureRevision += 1
    }

    /// ドラッグ&ドロップによる並べ替えの開始。ドラッグ1回分をまとめて1 undo ステップにするため、
    /// ドラッグ開始時にだけスナップショットを積む。以降の `reorderLineDuringDrag` はスナップショットを積まない。
    func beginLineDragReorder() {
        pushUndoSnapshot()
    }

    /// ドラッグ中の並べ替え。undo スナップショットは `beginLineDragReorder` 側で1回だけ積まれているため、
    /// ここでは積まない（ドラッグ中に何度も呼ばれるため）。
    func reorderLineDuringDrag(_ lineID: UUID, in segmentID: UUID, to targetIndex: Int) {
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
              let fromIndex = segments[segmentIndex].lines.firstIndex(where: { $0.id == lineID }) else { return }
        let clampedTarget = max(0, min(targetIndex, segments[segmentIndex].lines.count - 1))
        guard fromIndex != clampedTarget else { return }
        let line = segments[segmentIndex].lines.remove(at: fromIndex)
        segments[segmentIndex].lines.insert(line, at: clampedTarget)
        structureRevision += 1
    }

    // MARK: - 検索・置換

    /// 現在の検索クエリに対する全セグメント横断のヒット一覧。
    var matches: [ReviewMatch] {
        ReviewSearchEngine.findMatches(in: segments, query: search.query, isCaseSensitive: search.isCaseSensitive)
    }

    func matchCount(for segmentID: UUID) -> Int {
        matches.filter { $0.segmentID == segmentID }.count
    }

    /// `search.currentMatchIndex` は「現在フォーカスされているヒットの index」を表す。
    /// 既定値 -1 は「まだどのヒットへもジャンプしていない」ことを示すセンチネルで、この状態では
    /// 検索バーのラベルもレプリケートも index 0（先頭のヒット）を暗黙のカレントとして扱う。
    /// これにより、クエリを入力した直後に一度も ⌘G を押さずに「置換」を押しても先頭のヒットが
    /// 正しく置換され、逆に最初の ⌘G 押下でも先頭のヒットへジャンプする（いきなり2件目へ飛ばない）。
    func focusNextMatch() {
        let currentMatches = matches
        guard !currentMatches.isEmpty else { return }
        let nextIndex = search.currentMatchIndex < 0 ? 0 : (search.currentMatchIndex + 1) % currentMatches.count
        search.currentMatchIndex = nextIndex
        jumpToMatch(currentMatches[nextIndex])
    }

    func focusPreviousMatch() {
        let currentMatches = matches
        guard !currentMatches.isEmpty else { return }
        let previousIndex = search.currentMatchIndex <= 0 ? currentMatches.count - 1 : search.currentMatchIndex - 1
        search.currentMatchIndex = previousIndex
        jumpToMatch(currentMatches[previousIndex])
    }

    private func jumpToMatch(_ match: ReviewMatch) {
        selectedSegmentID = match.segmentID
        focusRequest = FocusRequest(segmentID: match.segmentID, target: match.target, token: (focusRequest?.token ?? 0) + 1)
    }

    /// 現在フォーカスされているヒット（未ジャンプ時は先頭のヒット）だけを置換する。
    func replaceCurrentMatch() {
        let currentMatches = matches
        let index = search.currentMatchIndex < 0 ? 0 : search.currentMatchIndex
        guard currentMatches.indices.contains(index) else { return }
        let match = currentMatches[index]

        pushUndoSnapshot()
        segments = ReviewSearchEngine.replacing(match, in: segments, replacement: search.replacement)
        structureRevision += 1

        let remainingMatches = matches
        if remainingMatches.isEmpty {
            search.currentMatchIndex = -1
        } else {
            let nextIndex = min(index, remainingMatches.count - 1)
            search.currentMatchIndex = nextIndex
            jumpToMatch(remainingMatches[nextIndex])
        }
    }

    /// クエリに一致する全箇所を一括置換する。
    func replaceAllMatches() {
        guard !search.query.isEmpty else { return }
        pushUndoSnapshot()
        segments = ReviewSearchEngine.replacingAll(
            in: segments,
            query: search.query,
            replacement: search.replacement,
            isCaseSensitive: search.isCaseSensitive
        )
        structureRevision += 1
        search.currentMatchIndex = -1
    }

    // MARK: - 発音辞書 / TTS 入力プレビュー

    /// 指定セグメントの実効発音辞書（レビュー開始時にグローバル＋プロフィールをマージ済み。
    /// `registerPronunciation` で新規登録した場合はその時点で再マージされる）。
    func effectivePronunciationEntries(for segmentID: UUID) -> [PronunciationEntry] {
        segment(withID: segmentID)?.pronunciationEntries ?? []
    }

    /// 「実際に TTS へ渡る入力」のプレビュー。`GeminiTTSService` と同じ `TTSInputComposer` を使うため、
    /// ここに表示される文字列は承認後に送信される文字列と一致する。
    func ttsInputPreview(for segmentID: UUID) -> String {
        guard let segment = segment(withID: segmentID) else { return "" }
        return TTSInputComposer.makeInput(
            dialogues: segment.dialogueLines,
            directionSettings: DirectionSettings(
                sceneDirection: segment.sceneDirection,
                pronunciationApplicationMode: segment.pronunciationApplicationMode
            ),
            pronunciationEntries: segment.pronunciationEntries
        )
    }

    /// 発音辞書へ新規エントリを登録し、現在レビュー中の全セグメントの実効辞書へ即座に反映する。
    func registerPronunciation(source: String, reading: String, scope: PronunciationScope) throws {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReading = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedReading.isEmpty else {
            throw PronunciationRegistrationError.emptySourceOrReading
        }

        let newEntry = PronunciationEntry(source: trimmedSource, reading: trimmedReading)
        try settingsStore.updateSettings { settings in
            switch scope {
            case .global:
                settings.globalPronunciationEntries.append(newEntry)
            case .profile:
                settings.directionSettings.pronunciationEntries.append(newEntry)
            }
        }

        let resolvedEntries = PronunciationDictionaryResolver.resolve(settings: settingsStore.currentSettings)
        for index in segments.indices {
            segments[index].pronunciationEntries = resolvedEntries
        }
        contentRevision += 1
    }

    /// 試聴ボタンを有効化してよいか。テストモードでは実 API を呼ばないため常に許可する。
    var canPreviewSegments: Bool {
        isTestMode || !settingsStore.currentSettings.activeTTSCredentialSets.isEmpty
    }

    // MARK: - TTS 試聴
    //
    // 誤爆防止のため4段構えにしている: (1) 初回は確認ダイアログを挟む
    // (2) 入力内容が変わっていなければキャッシュした音声を再生するだけで API を叩かない
    // (3) 同時に1本しか実行しない（新規リクエストは既存を必ずキャンセルしてから開始する）
    // (4) TTS 資格情報が1件も無効なら呼び出し元（View）がボタンを disable する

    /// 試聴をリクエストする。未確認なら確認ダイアログを要求し、確認済み（または「今後確認しない」設定済み）
    /// ならそのまま合成・再生する。キャッシュが有効な場合は確認なしで即再生する
    /// （API を消費しないため、確認を挟む理由がない）。
    func requestSegmentPreview(_ segmentID: UUID) {
        guard let segment = segment(withID: segmentID) else { return }
        let target = PreviewTarget.segment(segmentID)
        let contentHash = previewContentHash(dialogues: segment.dialogueLines, segment: segment)

        if let cached = previewCache[target], cached.contentHash == contentHash {
            playCachedPreview(target: target, wavData: cached.wavData)
            return
        }

        // テストモードは実 API を呼ばないため、確認ダイアログを挟む意味がない。
        if skipsPreviewConfirmation || isTestMode {
            performSegmentPreview(segmentID)
        } else {
            pendingPreviewConfirmationSegmentID = segmentID
        }
    }

    /// 指定した1発話だけを試聴する。空行は TTS へ送信しない。
    func requestLinePreview(_ lineID: UUID, in segmentID: UUID) {
        guard let segment = segment(withID: segmentID),
              let line = segment.lines.first(where: { $0.id == lineID }),
              !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = PreviewTarget.line(lineID)
        let dialogues = [line.asDialogueLine]
        let contentHash = previewContentHash(dialogues: dialogues, segment: segment)

        if let cached = previewCache[target], cached.contentHash == contentHash {
            playCachedPreview(target: target, wavData: cached.wavData)
            return
        }

        if skipsPreviewConfirmation || isTestMode {
            performLinePreview(LinePreviewRequest(segmentID: segmentID, lineID: lineID))
        } else {
            pendingLinePreviewConfirmation = LinePreviewRequest(segmentID: segmentID, lineID: lineID)
        }
    }

    /// 確認ダイアログでの「試聴する」応答。
    func confirmSegmentPreview(_ segmentID: UUID, skipFutureConfirmations: Bool) {
        pendingPreviewConfirmationSegmentID = nil
        if skipFutureConfirmations {
            skipsPreviewConfirmation = true
        }
        performSegmentPreview(segmentID)
    }

    /// 確認ダイアログでの「キャンセル」応答。
    func cancelPendingPreviewConfirmation() {
        pendingPreviewConfirmationSegmentID = nil
    }

    /// 行試聴の確認ダイアログでの応答。
    func confirmLinePreview(skipFutureConfirmations: Bool) {
        guard let request = pendingLinePreviewConfirmation else { return }
        pendingLinePreviewConfirmation = nil
        if skipFutureConfirmations {
            skipsPreviewConfirmation = true
        }
        performLinePreview(request)
    }

    /// 行試聴の確認ダイアログを閉じる。
    func cancelPendingLinePreviewConfirmation() {
        pendingLinePreviewConfirmation = nil
    }

    func stopSegmentPreview() {
        let audioService = interruptActivePreview()
        Task { await audioService?.stopPlayback() }
    }

    private func performSegmentPreview(_ segmentID: UUID) {
        guard let segment = segment(withID: segmentID) else { return }
        performPreview(
            target: .segment(segmentID),
            dialogues: segment.dialogueLines,
            segment: segment
        )
    }

    private func performLinePreview(_ request: LinePreviewRequest) {
        guard let segment = segment(withID: request.segmentID),
              let line = segment.lines.first(where: { $0.id == request.lineID }),
              !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performPreview(
            target: .line(request.lineID),
            dialogues: [line.asDialogueLine],
            segment: segment
        )
    }

    private func performPreview(
        target: PreviewTarget,
        dialogues: [DialogueLine],
        segment: ReviewSegmentDraft
    ) {
        let previousAudioService = interruptActivePreview()
        let audioService: any AudioPlaybackServiceProtocol = isTestMode
            ? TestModeAudioPlaybackService()
            : serviceFactory.makeAudioPlaybackService()
        let ttsService: any TTSService = isTestMode
            ? TestModeTTSService()
            : serviceFactory.makeTTSService(settings: settingsStore.currentSettings, cueSheetLogger: nil)
        activePreviewAudioService = audioService

        var narrationSettings = settingsStore.currentSettings
        narrationSettings.directionSettings.sceneDirection = segment.sceneDirection
        narrationSettings.directionSettings.pronunciationEntries = segment.pronunciationEntries
        narrationSettings.directionSettings.pronunciationApplicationMode = segment.pronunciationApplicationMode
        narrationSettings.globalPronunciationEntries = []
        // 台本生成時にスナップショットされた音声名を使う。ライブ設定のままだと、
        // プロフィール切替や Settings での声名変更後にプレビュー・本番・画面表示の声が食い違う。
        // 空文字（未設定）はライブ設定のフォールバックのままにする。
        if !segment.maleVoiceName.isEmpty {
            narrationSettings.voiceSettings.maleVoiceName = segment.maleVoiceName
        }
        if !segment.femaleVoiceName.isEmpty {
            narrationSettings.voiceSettings.femaleVoiceName = segment.femaleVoiceName
        }
        let contentHash = previewContentHash(dialogues: dialogues, segment: segment)

        setPreviewState(.synthesizing, for: target)
        previewTask = Task { [weak self] in
            guard let self else { return }
            await previousAudioService?.stopPlayback()
            guard !Task.isCancelled else { return }
            do {
                let result = try await ttsService.synthesize(dialogues: dialogues, settings: narrationSettings)
                guard !Task.isCancelled else { return }
                self.previewCache[target] = (contentHash, result.wavData)
                self.setPreviewState(.playing, for: target)
                try await audioService.play(wavData: result.wavData)
                guard !Task.isCancelled else { return }
                self.setPreviewState(.ready, for: target)
            } catch {
                guard !Task.isCancelled else { return }
                self.setPreviewState(.failed(error.localizedDescription), for: target)
            }
        }
    }

    private func playCachedPreview(target: PreviewTarget, wavData: Data) {
        let previousAudioService = interruptActivePreview()
        let audioService: any AudioPlaybackServiceProtocol = isTestMode
            ? TestModeAudioPlaybackService()
            : serviceFactory.makeAudioPlaybackService()
        activePreviewAudioService = audioService

        setPreviewState(.playing, for: target)
        previewTask = Task { [weak self] in
            guard let self else { return }
            await previousAudioService?.stopPlayback()
            guard !Task.isCancelled else { return }
            do {
                try await audioService.play(wavData: wavData)
                guard !Task.isCancelled else { return }
                self.setPreviewState(.ready, for: target)
            } catch {
                guard !Task.isCancelled else { return }
                self.setPreviewState(.failed(error.localizedDescription), for: target)
            }
        }
    }

    /// 発話指示・発話テキスト・発音辞書・音声名のいずれかが変わればキャッシュを無効化するためのハッシュ。
    private func previewContentHash(dialogues: [DialogueLine], segment: ReviewSegmentDraft) -> Int {
        var hasher = Hasher()
        hasher.combine(segment.sceneDirection)
        hasher.combine(segment.pronunciationApplicationMode)
        hasher.combine(segment.maleVoiceName)
        hasher.combine(segment.femaleVoiceName)
        for dialogue in dialogues {
            hasher.combine(dialogue.speaker)
            hasher.combine(dialogue.text)
        }
        for entry in segment.pronunciationEntries {
            hasher.combine(entry.source)
            hasher.combine(entry.reading)
            hasher.combine(entry.isEnabled)
        }
        return hasher.finalize()
    }

    private func interruptActivePreview() -> (any AudioPlaybackServiceProtocol)? {
        previewTask?.cancel()
        previewTask = nil
        let audioService = activePreviewAudioService
        activePreviewAudioService = nil
        resetActivePreviewStates()
        return audioService
    }

    private func resetActivePreviewStates() {
        for segmentID in Array(previewStates.keys) {
            guard previewStates[segmentID] == .playing || previewStates[segmentID] == .synthesizing else { continue }
            previewStates[segmentID] = previewCache[.segment(segmentID)] == nil ? .idle : .ready
        }
        for lineID in Array(linePreviewStates.keys) {
            guard linePreviewStates[lineID] == .playing || linePreviewStates[lineID] == .synthesizing else { continue }
            linePreviewStates[lineID] = previewCache[.line(lineID)] == nil ? .idle : .ready
        }
    }

    private func setPreviewState(_ state: SegmentPreviewState, for target: PreviewTarget) {
        switch target {
        case .segment(let segmentID):
            previewStates[segmentID] = state
        case .line(let lineID):
            linePreviewStates[lineID] = state
        }
    }

    // MARK: - 承認

    /// レビュー結果を `RadioOrchestrator.approveScripts(_:)` へ渡す形へ変換する。
    /// `droppingEmptyLines` が true の場合、空テキストの行はセグメントごとに除外する
    /// （そのセグメントの全行が空になる場合は安全のため除外しない）。
    func makeApprovedItems(droppingEmptyLines: Bool = true) -> [ReviewScriptItem] {
        segments.enumerated().map { index, segment in
            segment.makeReviewScriptItem(id: index, droppingEmptyLines: droppingEmptyLines)
        }
    }
}

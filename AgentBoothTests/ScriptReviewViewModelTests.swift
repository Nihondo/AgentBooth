import Combine
import XCTest
@testable import AgentBooth

@MainActor
final class ScriptReviewViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - キャレットバグの回帰テスト

    /// `updateLineText` はテキスト編集用の非 publish な書き込みメソッド。
    /// これが `objectWillChange` を発火すると、レビューウィンドウ内の全 TextEditor / TextField が
    /// 再構築され、NSTextView への文字列再代入によってキャレットが末尾へ飛ぶ不具合が再発する。
    func testUpdateLineTextDoesNotPublishObjectWillChange() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        var changeCount = 0
        viewModel.objectWillChange.sink { _ in changeCount += 1 }.store(in: &cancellables)

        let segment = viewModel.segments[0]
        let line = segment.lines[0]
        viewModel.updateLineText(segmentID: segment.id, lineID: line.id, text: "書き換えた発話テキスト")

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(viewModel.segments[0].lines[0].text, "書き換えた発話テキスト")
    }

    /// `updateSceneDirection` も同様に無通知であるべき。
    func testUpdateSceneDirectionDoesNotPublishObjectWillChange() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        var changeCount = 0
        viewModel.objectWillChange.sink { _ in changeCount += 1 }.store(in: &cancellables)

        let segment = viewModel.segments[0]
        viewModel.updateSceneDirection(segmentID: segment.id, text: "静かなトーンで")

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(viewModel.segments[0].sceneDirection, "静かなトーンで")
    }

    // MARK: - 初期化

    func testInitConvertsReviewScriptItemsIntoSegmentDrafts() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])

        XCTAssertEqual(viewModel.segments.count, 1)
        let segment = viewModel.segments[0]
        XCTAssertEqual(segment.segmentKey, "opening")
        XCTAssertEqual(segment.segmentLabel, "オープニング")
        XCTAssertEqual(segment.lines.map(\.text), item.script.dialogues.map(\.text))
        XCTAssertEqual(segment.lines.map(\.speaker), [.male, .female])
        XCTAssertEqual(viewModel.selectedSegmentID, segment.id)
    }

    // MARK: - 承認

    func testMakeApprovedItemsPreservesSegmentKeyAndOriginalScriptMetadata() {
        let item = makeItem(segmentKey: "closing", label: "クロージング")
        let viewModel = makeViewModel(items: [item])

        let segment = viewModel.segments[0]
        viewModel.updateLineText(segmentID: segment.id, lineID: segment.lines[0].id, text: "編集後のテキスト")

        let approved = viewModel.makeApprovedItems(droppingEmptyLines: false)

        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved[0].segmentKey, "closing")
        XCTAssertEqual(approved[0].script.segmentType, item.script.segmentType)
        XCTAssertEqual(approved[0].script.summaryBullets, item.script.summaryBullets)
        XCTAssertEqual(approved[0].script.dialogues[0].text, "編集後のテキスト")
    }

    func testMakeApprovedItemsDropsEmptyLinesWhenRequested() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        // 1行目を空にする
        viewModel.updateLineText(segmentID: segment.id, lineID: segment.lines[0].id, text: "   ")

        let approved = viewModel.makeApprovedItems(droppingEmptyLines: true)
        XCTAssertEqual(approved[0].script.dialogues.count, 1)
        XCTAssertEqual(approved[0].script.dialogues[0].text, segment.lines[1].text)
    }

    func testMakeApprovedItemsKeepsAllLinesWhenAllAreEmpty() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        for line in segment.lines {
            viewModel.updateLineText(segmentID: segment.id, lineID: line.id, text: "")
        }

        let approved = viewModel.makeApprovedItems(droppingEmptyLines: true)
        // 全行が空になる場合は安全のため除外しない
        XCTAssertEqual(approved[0].script.dialogues.count, segment.lines.count)
    }

    // MARK: - バリデーション

    func testValidationIssuesDetectsEmptyLine() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        viewModel.updateLineText(segmentID: segment.id, lineID: segment.lines[0].id, text: "")

        XCTAssertTrue(viewModel.validationIssues.contains {
            if case .emptyLine(let segmentID, let lineID) = $0 {
                return segmentID == segment.id && lineID == segment.lines[0].id
            }
            return false
        })
    }

    func testValidationIssuesEmptyWhenAllLinesHaveText() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        XCTAssertTrue(viewModel.validationIssues.isEmpty)
    }

    // MARK: - 構造編集（行の追加・削除・並べ替え・話者切替）

    func testAppendLineAddsLineAtEndAndBumpsStructureRevision() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segmentID = viewModel.segments[0].id
        let beforeCount = viewModel.segments[0].lines.count
        let beforeRevision = viewModel.structureRevision

        viewModel.appendLine(to: segmentID, speaker: .male)

        XCTAssertEqual(viewModel.segments[0].lines.count, beforeCount + 1)
        XCTAssertEqual(viewModel.segments[0].lines.last?.speaker, .male)
        XCTAssertEqual(viewModel.segments[0].lines.last?.text, "")
        XCTAssertEqual(viewModel.structureRevision, beforeRevision + 1)
    }

    func testInsertLineInsertsImmediatelyAfterTargetLine() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segment = viewModel.segments[0]
        let firstLineID = segment.lines[0].id

        viewModel.insertLine(in: segment.id, after: firstLineID, speaker: .female)

        let updated = viewModel.segments[0]
        XCTAssertEqual(updated.lines.count, segment.lines.count + 1)
        XCTAssertEqual(updated.lines[1].speaker, .female)
        XCTAssertEqual(updated.lines[1].text, "")
        // 元の2行目は3番目にずれている
        XCTAssertEqual(updated.lines[2].id, segment.lines[1].id)
    }

    func testRemoveLineDeletesTargetLine() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segment = viewModel.segments[0]
        let firstLineID = segment.lines[0].id

        viewModel.removeLine(firstLineID, in: segment.id)

        let updated = viewModel.segments[0]
        XCTAssertEqual(updated.lines.count, segment.lines.count - 1)
        XCTAssertFalse(updated.lines.contains { $0.id == firstLineID })
    }

    func testRemoveLineDoesNotDeleteLastRemainingLine() {
        let item = ReviewScriptItem(
            id: 0,
            segmentKey: "opening",
            segmentLabel: "オープニング",
            script: RadioScript(
                segmentType: "opening",
                dialogues: [DialogueLine(speaker: "male", text: "唯一の発話")],
                summaryBullets: [],
                track: nil
            ),
            sceneDirection: "",
            maleVoiceName: "Charon",
            femaleVoiceName: "Kore"
        )
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]
        XCTAssertEqual(segment.lines.count, 1)

        viewModel.removeLine(segment.lines[0].id, in: segment.id)

        XCTAssertEqual(viewModel.segments[0].lines.count, 1, "最後の1行は削除されない")
    }

    func testToggleSpeakerFlipsBetweenMaleAndFemale() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segment = viewModel.segments[0]
        let lineID = segment.lines[0].id
        XCTAssertEqual(segment.lines[0].speaker, .male)

        viewModel.toggleSpeaker(of: lineID, in: segment.id)
        XCTAssertEqual(viewModel.segments[0].lines[0].speaker, .female)

        viewModel.toggleSpeaker(of: lineID, in: segment.id)
        XCTAssertEqual(viewModel.segments[0].lines[0].speaker, .male)
    }

    // MARK: - undo

    func testUndoLastStructuralChangeRevertsAppendLine() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segmentID = viewModel.segments[0].id
        let beforeLines = viewModel.segments[0].lines
        XCTAssertFalse(viewModel.canUndo)

        viewModel.appendLine(to: segmentID, speaker: .male)
        XCTAssertTrue(viewModel.canUndo)
        XCTAssertEqual(viewModel.segments[0].lines.count, beforeLines.count + 1)

        viewModel.undoLastStructuralChange()

        XCTAssertEqual(viewModel.segments[0].lines.map(\.id), beforeLines.map(\.id))
        XCTAssertFalse(viewModel.canUndo)
    }

    func testUndoWithEmptyStackIsNoOp() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let beforeRevision = viewModel.structureRevision

        viewModel.undoLastStructuralChange()

        XCTAssertEqual(viewModel.structureRevision, beforeRevision)
    }

    func testDragReorderRecordsSingleUndoStepForWholeDrag() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segment = viewModel.segments[0]
        let firstLineID = segment.lines[0].id
        let originalOrder = segment.lines.map(\.id)

        // ドラッグ開始で1回だけ undo を積み、ドラッグ中の複数回の移動では積み増さない。
        viewModel.beginLineDragReorder()
        viewModel.reorderLineDuringDrag(firstLineID, in: segment.id, to: 1)
        viewModel.reorderLineDuringDrag(firstLineID, in: segment.id, to: 0)
        viewModel.reorderLineDuringDrag(firstLineID, in: segment.id, to: 1)

        XCTAssertTrue(viewModel.canUndo)
        viewModel.undoLastStructuralChange()
        XCTAssertEqual(viewModel.segments[0].lines.map(\.id), originalOrder)
        XCTAssertFalse(viewModel.canUndo, "ドラッグ全体で undo ステップは1つだけのはず")
    }

    // MARK: - 検索・置換

    func testMatchesFindsHitsAcrossSegments() {
        let viewModel = makeViewModel(items: [
            makeItem(segmentKey: "opening", label: "オープニング"),
            makeItem(segmentKey: "closing", label: "クロージング"),
        ])
        viewModel.search.query = "こんばんは"

        XCTAssertEqual(viewModel.matches.count, 2)
        XCTAssertEqual(viewModel.matchCount(for: viewModel.segments[0].id), 1)
        XCTAssertEqual(viewModel.matchCount(for: viewModel.segments[1].id), 1)
    }

    func testFocusNextMatchSelectsSegmentContainingTheMatch() {
        let viewModel = makeViewModel(items: [
            makeItem(segmentKey: "opening", label: "オープニング"),
            makeItem(segmentKey: "closing", label: "クロージング"),
        ])
        viewModel.selectedSegmentID = viewModel.segments[0].id
        viewModel.search.query = "こんばんは"

        viewModel.focusNextMatch()

        XCTAssertEqual(viewModel.selectedSegmentID, viewModel.segments[0].id)
        XCTAssertNotNil(viewModel.focusRequest)

        viewModel.focusNextMatch()
        XCTAssertEqual(viewModel.selectedSegmentID, viewModel.segments[1].id)
    }

    func testFocusNextMatchWrapsAroundToFirstMatch() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        viewModel.search.query = "お"  // "よろしくお願いします" に1件だけヒット

        viewModel.focusNextMatch()
        let firstToken = viewModel.focusRequest?.token
        viewModel.focusNextMatch()

        XCTAssertEqual(viewModel.search.currentMatchIndex, 0, "ヒットが1件のみなら折り返して同じ位置に戻る")
        XCTAssertNotEqual(viewModel.focusRequest?.token, firstToken, "同じ対象へ2回連続でジャンプしてもトークンは変わる")
    }

    func testReplaceCurrentMatchReplacesOnlyThatOccurrenceAndBumpsStructureRevision() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let beforeRevision = viewModel.structureRevision
        viewModel.search.query = "こんばんは"
        viewModel.search.replacement = "おはよう"

        viewModel.replaceCurrentMatch()

        XCTAssertEqual(viewModel.segments[0].lines[0].text, "おはよう、今夜も始まりました")
        XCTAssertEqual(viewModel.structureRevision, beforeRevision + 1)
        XCTAssertTrue(viewModel.canUndo)
    }

    func testReplaceAllMatchesReplacesEveryOccurrence() {
        let viewModel = makeViewModel(items: [
            makeItem(segmentKey: "opening", label: "オープニング"),
            makeItem(segmentKey: "closing", label: "クロージング"),
        ])
        viewModel.search.query = "こんばんは"
        viewModel.search.replacement = "おはよう"

        viewModel.replaceAllMatches()

        XCTAssertEqual(viewModel.segments[0].lines[0].text, "おはよう、今夜も始まりました")
        XCTAssertEqual(viewModel.segments[1].lines[0].text, "おはよう、今夜も始まりました")
        XCTAssertTrue(viewModel.matches.isEmpty)
    }

    func testUndoRevertsReplaceAllMatches() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let originalText = viewModel.segments[0].lines[0].text
        viewModel.search.query = "こんばんは"
        viewModel.search.replacement = "おはよう"

        viewModel.replaceAllMatches()
        XCTAssertNotEqual(viewModel.segments[0].lines[0].text, originalText)

        viewModel.undoLastStructuralChange()
        XCTAssertEqual(viewModel.segments[0].lines[0].text, originalText)
    }

    // MARK: - TTS 試聴

    func testRequestSegmentPreviewShowsConfirmationDialogFirstTime() {
        let (viewModel, _, _) = makeViewModelWithFakes(items: [makeItem(segmentKey: "opening", label: "オープニング")], isTestMode: false)
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)

        XCTAssertEqual(viewModel.pendingPreviewConfirmationSegmentID, segmentID)
        XCTAssertNil(viewModel.previewStates[segmentID])
    }

    func testRequestLinePreviewShowsConfirmationDialogFirstTime() {
        let (viewModel, _, _) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segment = viewModel.segments[0]
        let lineID = segment.lines[1].id

        viewModel.requestLinePreview(lineID, in: segment.id)

        XCTAssertEqual(
            viewModel.pendingLinePreviewConfirmation,
            LinePreviewRequest(segmentID: segment.id, lineID: lineID)
        )
        XCTAssertNil(viewModel.linePreviewStates[lineID])
    }

    func testConfirmLinePreviewSynthesizesOnlySelectedLine() async throws {
        var item = makeItem(segmentKey: "opening", label: "オープニング")
        item.pronunciationEntries = [PronunciationEntry(source: "よろしく", reading: "ヨロシク")]
        item.pronunciationApplicationMode = .replaceTranscript
        let (viewModel, ttsService, audioService) = makeViewModelWithFakes(
            items: [item],
            isTestMode: false
        )
        let segment = viewModel.segments[0]
        let selectedLine = segment.lines[1]

        viewModel.requestLinePreview(selectedLine.id, in: segment.id)
        viewModel.confirmLinePreview(skipFutureConfirmations: false)

        XCTAssertNil(viewModel.pendingLinePreviewConfirmation)
        try await waitUntil { viewModel.linePreviewStates[selectedLine.id] == .ready }

        let recordedDialogues = await ttsService.recordedDialogues
        let recordedSettings = await ttsService.recordedSettings
        let playCount = await audioService.playCount
        XCTAssertEqual(recordedDialogues, [[selectedLine.asDialogueLine]])
        XCTAssertEqual(recordedSettings.first?.directionSettings.pronunciationApplicationMode, .replaceTranscript)
        let input = TTSInputComposer.makeInput(
            dialogues: try XCTUnwrap(recordedDialogues.first),
            directionSettings: try XCTUnwrap(recordedSettings.first?.directionSettings),
            pronunciationEntries: try XCTUnwrap(recordedSettings.first?.directionSettings.pronunciationEntries)
        )
        // 単一話者(この行だけ)の入力なので、話者ラベルは付かない。
        XCTAssertTrue(input.contains("ヨロシクお願いします"))
        XCTAssertFalse(input.contains("Female:"))
        XCTAssertFalse(input.contains("Pronunciation dictionary"))
        XCTAssertEqual(playCount, 1)
    }

    func testRequestLinePreviewReusesCacheWithoutCallingTTSAgain() async throws {
        let (viewModel, ttsService, audioService) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segment = viewModel.segments[0]
        let lineID = segment.lines[0].id

        viewModel.requestLinePreview(lineID, in: segment.id)
        viewModel.confirmLinePreview(skipFutureConfirmations: false)
        try await waitUntil { viewModel.linePreviewStates[lineID] == .ready }

        viewModel.requestLinePreview(lineID, in: segment.id)

        XCTAssertNil(viewModel.pendingLinePreviewConfirmation, "キャッシュ済みの発話は確認ダイアログを出さない")
        try await waitUntil { viewModel.linePreviewStates[lineID] == .ready }

        let synthesisCount = await ttsService.recordedDialogues.count
        let playCount = await audioService.playCount
        XCTAssertEqual(synthesisCount, 1, "同じ発話内容は TTS を再度呼ばない")
        XCTAssertEqual(playCount, 2, "キャッシュ音声も再生する")
    }

    /// プレビューはライブ設定の音声名ではなく、台本生成時にスナップショットされたセグメントの音声名を
    /// 使わなければならない。そうでないと、プロフィール切替後にプレビュー・本番・画面表示の声が食い違う。
    /// ここではライブ設定を先に書き換えてから ViewModel を作り、後から作られた設定に引きずられていないことを確認する。
    func testConfirmLinePreviewUsesSegmentSnapshotVoiceNamesNotLiveSettings() async throws {
        let (_, _, store) = makeSettingsStore()
        try store.updateSettings { settings in
            settings.ttsCredentialSets = [TTSCredentialSet(label: "test", apiKey: "key", modelName: "model")]
            settings.voiceSettings.maleVoiceName = "LiveMaleVoice"
            settings.voiceSettings.femaleVoiceName = "LiveFemaleVoice"
        }
        let item = makeItem(
            segmentKey: "opening",
            label: "オープニング",
            maleVoiceName: "SegmentMaleVoice",
            femaleVoiceName: "SegmentFemaleVoice"
        )
        let ttsService = FakeTTSService()
        let viewModel = ScriptReviewViewModel(
            items: [item],
            settingsStore: store,
            serviceFactory: FakeServiceFactory(
                musicService: FakeMusicService(),
                ttsService: ttsService,
                audioPlaybackService: FakeAudioPlaybackService()
            ),
            isTestMode: false
        )
        let segment = viewModel.segments[0]
        let lineID = segment.lines[0].id

        viewModel.requestLinePreview(lineID, in: segment.id)
        viewModel.confirmLinePreview(skipFutureConfirmations: false)
        try await waitUntil { viewModel.linePreviewStates[lineID] == .ready }

        let recordedSettings = await ttsService.recordedSettings
        XCTAssertEqual(recordedSettings.first?.voiceSettings.maleVoiceName, "SegmentMaleVoice")
        XCTAssertEqual(recordedSettings.first?.voiceSettings.femaleVoiceName, "SegmentFemaleVoice")
    }

    // MARK: - 永続音声キャッシュ（本番再生・他セッションのプレビューと共有）

    /// レビューの試聴で合成した音声は、本番再生（`RadioOrchestrator`）が計算するのと
    /// 同じ fingerprint で永続キャッシュへ保存される。
    func testConfirmSegmentPreviewSavesAudioToScriptStoreWithMatchingFingerprint() async throws {
        let scriptStore = FakePreGeneratedScriptStore()
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let (viewModel, _, _) = makeViewModelWithFakes(items: [item], isTestMode: false, scriptStore: scriptStore)
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        let saveCallCount = await scriptStore.saveNarrationAudioCallCount
        XCTAssertEqual(saveCallCount, 1)

        let expectedFingerprint = NarrationAudioFingerprint.make(
            dialogues: item.script.dialogues,
            settings: makeExpectedSegmentNarrationSettings(sceneDirection: item.sceneDirection)
        )
        let savedAudio = await scriptStore.loadNarrationAudio(fingerprint: expectedFingerprint)
        XCTAssertNotNil(savedAudio, "本番再生と同じ fingerprint で読み出せること")
    }

    /// 本番再生や過去のレビューが既に作った音声が永続キャッシュにあれば、確認ダイアログを出さず
    /// API も消費せずに再生する。
    func testRequestSegmentPreviewReusesPersistedAudioWithoutConfirmationOrTTSCall() async throws {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let fingerprint = NarrationAudioFingerprint.make(
            dialogues: item.script.dialogues,
            settings: makeExpectedSegmentNarrationSettings(sceneDirection: item.sceneDirection)
        )
        let scriptStore = FakePreGeneratedScriptStore(narrationAudioByFingerprint: [fingerprint: Data([0x01, 0x02])])
        let (viewModel, ttsService, audioService) = makeViewModelWithFakes(
            items: [item],
            isTestMode: false,
            scriptStore: scriptStore
        )
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        XCTAssertNil(viewModel.pendingPreviewConfirmationSegmentID, "永続キャッシュがヒットすれば確認ダイアログを出さない")
        let recordedDialogues = await ttsService.recordedDialogues
        let playCount = await audioService.playCount
        XCTAssertTrue(recordedDialogues.isEmpty, "キャッシュヒット時は TTS を呼ばない")
        XCTAssertEqual(playCount, 1)
    }

    /// 永続キャッシュに何かは入っているが、このセグメントの fingerprint とは一致しない場合
    /// （台本を編集した後など）は、通常どおり確認ダイアログを要求する。
    func testRequestSegmentPreviewShowsConfirmationWhenPersistedAudioFingerprintDoesNotMatch() async throws {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let scriptStore = FakePreGeneratedScriptStore(narrationAudioByFingerprint: ["stale-fingerprint": Data([0x01])])
        let (viewModel, ttsService, _) = makeViewModelWithFakes(items: [item], isTestMode: false, scriptStore: scriptStore)
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        try await waitUntil { viewModel.pendingPreviewConfirmationSegmentID == segmentID }

        let recordedDialogues = await ttsService.recordedDialogues
        XCTAssertTrue(recordedDialogues.isEmpty, "確認ダイアログを出した段階ではまだ合成しない")
    }

    /// セグメント試聴に送る台詞は、承認後に実際に TTS へ渡る内容（空行を除外したもの）と一致させる。
    /// 揃えないと、同じ内容の試聴と本番再生で fingerprint が食い違いキャッシュが共有できない。
    func testSegmentPreviewDropsEmptyLinesToMatchApprovedScript() async throws {
        var item = makeItem(segmentKey: "opening", label: "オープニング")
        item.script.dialogues[1].text = "   "
        let (viewModel, ttsService, _) = makeViewModelWithFakes(items: [item], isTestMode: false)
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        let recordedDialogues = await ttsService.recordedDialogues
        XCTAssertEqual(recordedDialogues.first?.count, 1, "空行は本番同様に除外されて TTS へ渡る")
        XCTAssertEqual(recordedDialogues.first?.first?.text, "こんばんは、今夜も始まりました")
    }

    /// `scriptStore` を注入しない場合は従来どおり同期的に確認ダイアログを出す
    /// （永続キャッシュの確認自体を行わない）。
    func testRequestSegmentPreviewWithoutScriptStoreShowsConfirmationSynchronously() {
        let (viewModel, _, _) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)

        XCTAssertEqual(viewModel.pendingPreviewConfirmationSegmentID, segmentID)
    }

    private func makeExpectedSegmentNarrationSettings(sceneDirection: String) -> AppSettings {
        var settings = AppSettings()
        settings.ttsCredentialSets = [TTSCredentialSet(label: "test", apiKey: "key", modelName: "model")]
        settings.directionSettings.sceneDirection = sceneDirection
        return settings
    }

    func testConfirmSegmentPreviewSynthesizesAndPlaysThenBecomesReady() async throws {
        let (viewModel, ttsService, audioService) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)

        XCTAssertNil(viewModel.pendingPreviewConfirmationSegmentID)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        let recordedSettingsCount = await ttsService.recordedSettings.count
        let playCount = await audioService.playCount
        XCTAssertEqual(recordedSettingsCount, 1)
        XCTAssertEqual(playCount, 1)
    }

    func testRequestSegmentPreviewReusesCacheWithoutCallingTTSAgain() async throws {
        let (viewModel, ttsService, audioService) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        // 内容を変えずに再度リクエスト。キャッシュがヒットするので確認ダイアログも API 呼び出しも発生しない。
        viewModel.requestSegmentPreview(segmentID)

        XCTAssertNil(viewModel.pendingPreviewConfirmationSegmentID, "キャッシュヒット時は確認ダイアログを出さない")
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        let recordedSettingsCount = await ttsService.recordedSettings.count
        let playCount = await audioService.playCount
        XCTAssertEqual(recordedSettingsCount, 1, "キャッシュヒット時は TTS を再度呼ばない")
        XCTAssertEqual(playCount, 2, "再生は毎回行う")
    }

    func testEditingTextInvalidatesPreviewCacheAndRequiresReconfirmation() async throws {
        let (viewModel, _, _) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segmentID = viewModel.segments[0].id
        let lineID = viewModel.segments[0].lines[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)
        try await waitUntil { viewModel.previewStates[segmentID] == .ready }

        viewModel.updateLineText(segmentID: segmentID, lineID: lineID, text: "書き換えたテキスト")
        viewModel.requestSegmentPreview(segmentID)

        XCTAssertEqual(viewModel.pendingPreviewConfirmationSegmentID, segmentID, "内容が変わったらキャッシュは無効になり再確認が必要")
    }

    func testConfirmSegmentPreviewWithSkipFutureConfirmationsSuppressesFutureDialogs() async throws {
        let (viewModel, _, _) = makeViewModelWithFakes(
            items: [
                makeItem(segmentKey: "opening", label: "オープニング"),
                makeItem(segmentKey: "closing", label: "クロージング"),
            ],
            isTestMode: false
        )
        let firstID = viewModel.segments[0].id
        let secondID = viewModel.segments[1].id

        viewModel.requestSegmentPreview(firstID)
        viewModel.confirmSegmentPreview(firstID, skipFutureConfirmations: true)
        try await waitUntil { viewModel.previewStates[firstID] == .ready }

        viewModel.requestSegmentPreview(secondID)

        XCTAssertNil(viewModel.pendingPreviewConfirmationSegmentID, "「以後確認しない」の後は別セグメントでも確認ダイアログを出さない")
        try await waitUntil { viewModel.previewStates[secondID] == .ready }
    }

    func testIsTestModeSkipsConfirmationDialog() async throws {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)

        XCTAssertNil(viewModel.pendingPreviewConfirmationSegmentID, "テストモードでは実 API を叩かないため確認ダイアログを出さない")
    }

    func testStopSegmentPreviewResetsStateToReadyWhenCacheExists() async throws {
        let (viewModel, _, audioService) = makeViewModelWithFakes(
            items: [makeItem(segmentKey: "opening", label: "オープニング")],
            isTestMode: false
        )
        let segmentID = viewModel.segments[0].id

        viewModel.requestSegmentPreview(segmentID)
        viewModel.confirmSegmentPreview(segmentID, skipFutureConfirmations: false)
        try await waitUntil { viewModel.previewStates[segmentID] == .playing }

        viewModel.stopSegmentPreview()

        try await waitUntil { await !audioService.isPlaying }
        XCTAssertEqual(viewModel.previewStates[segmentID], .ready)
    }

    // MARK: - TTS 入力プレビュー / 発音辞書クイック登録

    func testTTSInputPreviewMatchesTTSInputComposerOutput() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        let preview = viewModel.ttsInputPreview(for: segment.id)
        let expected = TTSInputComposer.makeInput(
            dialogues: segment.dialogueLines,
            directionSettings: DirectionSettings(sceneDirection: segment.sceneDirection),
            pronunciationEntries: segment.pronunciationEntries
        )
        XCTAssertEqual(preview, expected)
    }

    func testTTSInputPreviewReflectsLiveTextEdits() {
        let item = makeItem(segmentKey: "opening", label: "オープニング")
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        viewModel.updateLineText(segmentID: segment.id, lineID: segment.lines[0].id, text: "書き換え後のテキスト")

        XCTAssertTrue(viewModel.ttsInputPreview(for: segment.id).contains("書き換え後のテキスト"))
    }

    func testTTSInputPreviewUsesPronunciationReplacementMode() {
        var item = makeItem(segmentKey: "opening", label: "オープニング")
        item.pronunciationEntries = [PronunciationEntry(source: "こんばんは", reading: "コンバンワ")]
        item.pronunciationApplicationMode = .replaceTranscript
        let viewModel = makeViewModel(items: [item])
        let segment = viewModel.segments[0]

        let preview = viewModel.ttsInputPreview(for: segment.id)

        XCTAssertTrue(preview.contains("Male: コンバンワ、今夜も始まりました"))
        XCTAssertFalse(preview.contains("Pronunciation dictionary"))
        XCTAssertTrue(segment.lines[0].text.contains("こんばんは"), "レビュー画面の原文は置換しない")
    }

    func testRegisterPronunciationPersistsToProfileScopeAndUpdatesPreview() throws {
        let (viewModel, store) = makeViewModelWithStore(items: [makeItem(segmentKey: "opening", label: "オープニング")])
        let segment = viewModel.segments[0]

        try viewModel.registerPronunciation(source: "こんばんは", reading: "コンバンワ", scope: .profile)

        XCTAssertEqual(store.currentSettings.directionSettings.pronunciationEntries.map(\.source), ["こんばんは"])
        XCTAssertEqual(viewModel.effectivePronunciationEntries(for: segment.id).map(\.source), ["こんばんは"])
        XCTAssertTrue(viewModel.ttsInputPreview(for: segment.id).contains("「こんばんは」 = 「コンバンワ」"))
    }

    func testRegisterPronunciationPersistsToGlobalScope() throws {
        let (viewModel, store) = makeViewModelWithStore(items: [makeItem(segmentKey: "opening", label: "オープニング")])

        try viewModel.registerPronunciation(source: "よろしく", reading: "ヨロシク", scope: .global)

        XCTAssertEqual(store.currentSettings.globalPronunciationEntries.map(\.source), ["よろしく"])
        XCTAssertTrue(store.currentSettings.directionSettings.pronunciationEntries.isEmpty)
    }

    func testRegisterPronunciationThrowsWhenSourceOrReadingIsEmpty() {
        let viewModel = makeViewModel(items: [makeItem(segmentKey: "opening", label: "オープニング")])

        XCTAssertThrowsError(try viewModel.registerPronunciation(source: "", reading: "よみ", scope: .profile))
        XCTAssertThrowsError(try viewModel.registerPronunciation(source: "表記", reading: "  ", scope: .profile))
    }

    // MARK: - Helpers

    private func makeViewModel(items: [ReviewScriptItem]) -> ScriptReviewViewModel {
        let (_, _, store) = makeSettingsStore()
        return ScriptReviewViewModel(
            items: items,
            settingsStore: store,
            serviceFactory: FakeServiceFactory(musicService: FakeMusicService()),
            isTestMode: true
        )
    }

    private func makeViewModelWithStore(items: [ReviewScriptItem]) -> (ScriptReviewViewModel, AppSettingsStore) {
        let (_, _, store) = makeSettingsStore()
        let viewModel = ScriptReviewViewModel(
            items: items,
            settingsStore: store,
            serviceFactory: FakeServiceFactory(musicService: FakeMusicService()),
            isTestMode: true
        )
        return (viewModel, store)
    }

    /// 試聴フローのテスト用。`isTestMode: false` でも `FakeTTSService` / `FakeAudioPlaybackService` を使うため
    /// 実 API・実再生は発生しない。`store.currentSettings` に有効な TTS 資格情報を1件設定しておく。
    private func makeViewModelWithFakes(
        items: [ReviewScriptItem],
        isTestMode: Bool,
        scriptStore: (any PreGeneratedScriptStoreProtocol)? = nil
    ) -> (ScriptReviewViewModel, FakeTTSService, FakeAudioPlaybackService) {
        let (_, _, store) = makeSettingsStore()
        try? store.updateSettings { settings in
            settings.ttsCredentialSets = [TTSCredentialSet(label: "test", apiKey: "key", modelName: "model")]
        }
        let ttsService = FakeTTSService()
        let audioService = FakeAudioPlaybackService()
        let viewModel = ScriptReviewViewModel(
            items: items,
            settingsStore: store,
            serviceFactory: FakeServiceFactory(
                musicService: FakeMusicService(),
                ttsService: ttsService,
                audioPlaybackService: audioService
            ),
            isTestMode: isTestMode,
            scriptStore: scriptStore
        )
        return (viewModel, ttsService, audioService)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func makeSettingsStore() -> (UserDefaults, KeychainStore, AppSettingsStore) {
        let suiteName = "AgentBoothTests.ScriptReviewViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainStore = KeychainStore(serviceName: suiteName)
        let store = AppSettingsStore(userDefaults: defaults, keychainStore: keychainStore)
        return (defaults, keychainStore, store)
    }

    private func makeItem(
        segmentKey: String,
        label: String,
        maleVoiceName: String = "Charon",
        femaleVoiceName: String = "Kore"
    ) -> ReviewScriptItem {
        ReviewScriptItem(
            id: 0,
            segmentKey: segmentKey,
            segmentLabel: label,
            script: RadioScript(
                segmentType: "opening",
                dialogues: [
                    DialogueLine(speaker: "male", text: "こんばんは、今夜も始まりました"),
                    DialogueLine(speaker: "female", text: "よろしくお願いします")
                ],
                summaryBullets: ["番組の挨拶をした"],
                track: nil
            ),
            sceneDirection: "落ち着いたトーンで",
            maleVoiceName: maleVoiceName,
            femaleVoiceName: femaleVoiceName
        )
    }
}

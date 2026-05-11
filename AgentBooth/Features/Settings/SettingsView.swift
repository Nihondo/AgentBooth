import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case profileManagement
    case programInfo
    case voiceDirection
    case playbackBalance
    case bgmJingle
    case service
    case generation
    case recording
    case update

    var id: String { rawValue }

    static let profileCategories: [SettingsCategory] = [.profileManagement]
    static let showProfileCategories: [SettingsCategory] = [
        .programInfo,
        .voiceDirection,
        .playbackBalance,
        .bgmJingle,
    ]
    static let appCategories: [SettingsCategory] = [.service, .generation, .recording, .update]

    var title: String {
        switch self {
        case .profileManagement:
            return String(localized: "プロフィール管理")
        case .programInfo:
            return String(localized: "番組情報")
        case .voiceDirection:
            return String(localized: "声と話し方")
        case .playbackBalance:
            return String(localized: "再生バランス")
        case .bgmJingle:
            return String(localized: "BGM・ジングル")
        case .service:
            return String(localized: "サービス")
        case .generation:
            return String(localized: "生成・TTS接続")
        case .recording:
            return String(localized: "録音")
        case .update:
            return String(localized: "アップデート")
        }
    }

    var systemImageName: String {
        switch self {
        case .profileManagement:
            return "person.crop.circle"
        case .programInfo:
            return "dot.radiowaves.left.and.right"
        case .voiceDirection:
            return "waveform"
        case .playbackBalance:
            return "slider.horizontal.3"
        case .bgmJingle:
            return "music.note.list"
        case .service:
            return "slider.horizontal.3"
        case .generation:
            return "terminal"
        case .recording:
            return "record.circle"
        case .update:
            return "arrow.down.circle"
        }
    }

    var descriptionText: String {
        switch self {
        case .profileManagement:
            return String(localized: "番組プロフィールを作成、複製、切り替えます。")
        case .programInfo:
            return String(localized: "番組名やパーソナリティ名を設定します。")
        case .voiceDirection:
            return String(localized: "声、話し方、時間帯別のディレクションを設定します。")
        case .playbackBalance:
            return String(localized: "曲とトークの重なり方や音量を設定します。")
        case .bgmJingle:
            return String(localized: "トーク中のBGMと番組ジングルを設定します。")
        case .service:
            return String(localized: "音楽サービスの設定を行います。")
        case .generation:
            return String(localized: "Gemini TTS と台本生成 CLI の設定を行います。")
        case .recording:
            return String(localized: "番組のシステム音声キャプチャ録音の設定を行います。")
        case .update:
            return String(localized: "アプリのアップデートを確認します。")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    @State private var draftSettings = AppSettings()
    @State private var selectedCategory: SettingsCategory? = .profileManagement
    @State private var errorMessage: String?
    @State private var newProfileName: String = ""
    /// カスタム CLI 引数の編集バッファ（1 行 1 引数）。draftSettings とは非同期に管理し、空行は保存時に除外。
    @State private var customArgsText: String = ""
    @State private var customModelArgsText: String = ""
    @ObservedObject private var ytStore = LiveAppServiceFactory.sharedYouTubeMusicStore
    @ObservedObject private var spotifyStore = LiveAppServiceFactory.sharedSpotifyStore

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCategory) {
                Section("プロフィール") {
                    ForEach(SettingsCategory.profileCategories) { category in
                        Label(category.title, systemImage: category.systemImageName)
                            .tag(category)
                    }
                }

                Section("番組プロフィール") {
                    ForEach(SettingsCategory.showProfileCategories) { category in
                        Label(category.title, systemImage: category.systemImageName)
                            .tag(category)
                    }
                }

                Section("アプリ設定") {
                    ForEach(SettingsCategory.appCategories) { category in
                        Label(category.title, systemImage: category.systemImageName)
                            .tag(category)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            detailView
        }
        .frame(minWidth: 860, minHeight: 620)
        .navigationTitle("AgentBooth 設定")
        .onAppear {
            draftSettings = settingsStore.currentSettings
            customArgsText = draftSettings.customCLIArguments.joined(separator: "\n")
            customModelArgsText = draftSettings.customCLIModelArguments.joined(separator: "\n")
            ytStore.setUserAgent(settingsStore.currentSettings.youtubeMusicUserAgent)
            Task { @MainActor in
                await spotifyStore.refreshLoginStatus()
            }
        }
        .onChange(of: draftSettings) {
            saveSettings()
        }
        .onChange(of: customArgsText) {
            draftSettings.customCLIArguments = customArgsText
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
        }
        .onChange(of: customModelArgsText) {
            draftSettings.customCLIModelArguments = customModelArgsText
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let category = selectedCategory ?? .profileManagement

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title)
                        .font(.title2.weight(.semibold))
                    Text(category.descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                contentView(for: category)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func contentView(for category: SettingsCategory) -> some View {
        switch category {
        case .profileManagement:
            profileManagementView
        case .programInfo:
            programInfoSettingsView
        case .voiceDirection:
            voiceDirectionSettingsView
        case .playbackBalance:
            playbackBalanceSettingsView
        case .bgmJingle:
            bgmJingleSettingsView
        case .service:
            serviceSettingsView
        case .generation:
            generationTTSSettingsView
        case .recording:
            recordingSettingsView
        case .update:
            UpdateSettingsView()
        }
    }

    private var profileManagementView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("アクティブプロフィール") {
                settingsRow("現在のプロフィール") {
                    Picker("現在のプロフィール", selection: Binding(
                        get: { draftSettings.activeProfileId ?? settingsStore.showProfiles.first?.id },
                        set: { profileID in
                            if let profileID {
                                selectProfile(profileID)
                            }
                        }
                    )) {
                        ForEach(settingsStore.showProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280, alignment: .leading)
                }
            }

            settingsGroup("プロフィール一覧") {
                ForEach(settingsStore.showProfiles) { profile in
                    HStack(spacing: 10) {
                        TextField("プロフィール名", text: profileNameBinding(profile.id))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)

                        if profile.id == draftSettings.activeProfileId {
                            Label("使用中", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }

                        Spacer()

                        Button("複製") {
                            duplicateProfile(profile.id)
                        }

                        Button("削除") {
                            deleteProfile(profile.id)
                        }
                        .disabled(settingsStore.showProfiles.count <= 1)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    TextField("新規プロフィール名", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)

                    Button("新規作成") {
                        createProfile()
                    }
                }
            }

            settingsGroup("含まれる設定") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("番組名、周波数、地域、パーソナリティ名", systemImage: "dot.radiowaves.left.and.right")
                    Label("声、話し方、時間帯別ディレクション", systemImage: "waveform")
                    Label("オーバーラップ、音量、フェード、最大再生秒数", systemImage: "slider.horizontal.3")
                    Label("BGM、ジングル、素材ファイル、音量", systemImage: "music.note.list")
                    Text("音楽サービス、ログイン、TTS資格情報、台本生成CLI、録音先はアプリ共通設定です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private var programInfoSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("番組情報") {
                settingsRow("番組名") {
                    TextField("AgentBooth Radio", text: $draftSettings.radioShowSettings.showName)
                    .textFieldStyle(.roundedBorder)
                }

                settingsRow("周波数・チャンネル名") {
                    TextField("例: 77.5 FM", text: $draftSettings.radioShowSettings.frequency)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("地域名") {
                    TextField("例: 東京", text: optionalTextBinding(\.radioShowSettings.locationName))
                        .textFieldStyle(.roundedBorder)
                }
            }

            settingsGroup("パーソナリティ") {
                settingsRow("男性ホスト名") {
                    TextField("田中", text: $draftSettings.personalitySettings.maleHostName)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("女性ホスト名") {
                    TextField("佐藤", text: $draftSettings.personalitySettings.femaleHostName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var voiceDirectionSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("音声") {
                settingsRow("男性ボイス") {
                    TextField("Charon", text: $draftSettings.voiceSettings.maleVoiceName)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("女性ボイス") {
                    TextField("Kore", text: $draftSettings.voiceSettings.femaleVoiceName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            settingsGroup("ディレクション") {
                settingsRow("シーン・セリフの指示") {
                    TextField("例: 深夜帯、静かに話す", text: $draftSettings.directionSettings.sceneDirection, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...)
                }
            }

            settingsGroup("時間帯別プリセット") {
                ForEach(TimeBand.allCases) { timeBand in
                    settingsRow("\(timeBand.displayName)（\(timeBand.hourRangeDescription)）") {
                        TextField(
                            timeBandPresetPlaceholder(timeBand),
                            text: timeBandPresetBinding(timeBand),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...)
                    }
                }
            }
        }
    }

    private var playbackBalanceSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("再生モード") {
                settingsRow("オーバーラップモード") {
                    Picker("オーバーラップモード", selection: $draftSettings.defaultOverlapMode) {
                        ForEach(OverlapMode.orderedCases) { overlapMode in
                            Text(overlapMode.displayName).tag(overlapMode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }
            }

            settingsGroup("再生バランス") {
                settingsRow("通常音量") {
                    playbackBalanceField(
                        placeholder: "100",
                        value: $draftSettings.volumeSettings.normalVolume,
                        formatter: numberFormatter,
                        description: "通常再生時の基準音量"
                    )
                }

                settingsRow("トーク時音量") {
                    playbackBalanceField(
                        placeholder: "25",
                        value: $draftSettings.volumeSettings.talkVolume,
                        formatter: numberFormatter,
                        description: "トーク重なり中の楽曲音量"
                    )
                }

                settingsRow("フェード秒数") {
                    playbackBalanceField(
                        placeholder: "5.0",
                        value: $draftSettings.volumeSettings.fadeDuration,
                        formatter: decimalFormatter,
                        description: "音量を滑らかに変える時間"
                    )
                }

                settingsRow("楽曲先行開始秒数") {
                    playbackBalanceField(
                        placeholder: "10",
                        value: $draftSettings.volumeSettings.musicLeadSeconds,
                        formatter: decimalFormatter,
                        description: "トーク終了前に次曲を重ねる秒数"
                    )
                }

                settingsRow("曲終了前のトーク再開秒数") {
                    playbackBalanceField(
                        placeholder: "10",
                        value: $draftSettings.volumeSettings.fadeEarlySeconds,
                        formatter: numberFormatter,
                        description: "曲終了前にトークを重ねる秒数"
                    )
                }

                settingsRow("楽曲最大再生秒数") {
                    playbackBalanceField(
                        placeholder: "0（制限なし）",
                        value: $draftSettings.volumeSettings.maxPlaybackDurationSeconds,
                        formatter: numberFormatter,
                        description: "1曲あたりの再生上限。0で無制限"
                    )
                }
            }
        }
    }

    private var bgmJingleSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("BGM・ジングル") {
                settingsRow("") {
                    Toggle("ベッド BGM を有効にする", isOn: $draftSettings.bgmSettings.isBedEnabled)
                }

                settingsRow("") {
                    Toggle("オープニングでジングルを使う", isOn: $draftSettings.bgmSettings.isOpeningJingleEnabled)
                }

                settingsRow("") {
                    Toggle("クロージングでジングルを使う", isOn: $draftSettings.bgmSettings.isClosingJingleEnabled)
                }

                audioAssetSourceRow(
                    title: "ベッド BGM",
                    source: $draftSettings.bgmSettings.bedAudioSource
                )

                audioAssetSourceRow(
                    title: "オープニングジングル",
                    source: $draftSettings.bgmSettings.openingJingleSource
                )

                audioAssetSourceRow(
                    title: "クロージングジングル",
                    source: $draftSettings.bgmSettings.closingJingleSource
                )

                settingsRow("ベッド音量") {
                    volumeSlider(value: $draftSettings.bgmSettings.bedVolume)
                }

                settingsRow("ジングル音量") {
                    volumeSlider(value: $draftSettings.bgmSettings.jingleVolume)
                }

                settingsRow("ベッドフェードアウト秒数") {
                    playbackBalanceField(
                        placeholder: "1.2",
                        value: $draftSettings.bgmSettings.bedFadeOutDuration,
                        formatter: decimalFormatter,
                        description: "楽曲開始前やトーク終了後にBGMを止める時間"
                    )
                }
            }
        }
    }

    private var serviceSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("既定値") {
                settingsRow("既定のサービス") {
                    Picker("既定のサービス", selection: $draftSettings.defaultMusicService) {
                        ForEach(MusicServiceKind.allCases) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }
            }

            settingsGroup("YouTube Music") {
                youtubeMusicLoginRow
            }

            settingsGroup("Spotify") {
                spotifyLoginRow
            }
        }
    }

    @ViewBuilder
    private var youtubeMusicLoginRow: some View {
        settingsRow("ログイン状態") {
            HStack(spacing: 10) {
                Circle()
                    .fill(ytStore.isLoggedIn ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(ytStore.isLoggedIn ? "ログイン済み" : "未ログイン")
                    .foregroundStyle(ytStore.isLoggedIn ? .primary : .secondary)
            }
        }
        settingsRow("") {
            Button("YouTube Music でログイン") {
                YouTubeMusicBrowserWindowController.shared.open(
                    store: LiveAppServiceFactory.sharedYouTubeMusicStore
                )
            }
        }
        settingsRow("User Agent") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Safari UA", text: $draftSettings.youtubeMusicUserAgent)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("空欄にすると WKWebView デフォルト UA を使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var spotifyLoginRow: some View {
        settingsRow("ログイン状態") {
            HStack(spacing: 10) {
                Circle()
                    .fill(spotifyStore.isLoggedIn ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(spotifyStore.isLoggedIn ? "ログイン済み" : "未ログイン")
                    .foregroundStyle(spotifyStore.isLoggedIn ? .primary : .secondary)
            }
        }
        settingsRow("") {
            HStack(spacing: 10) {
                Button("Spotify でログイン") {
                    SpotifyBrowserWindowController.shared.open(
                        store: LiveAppServiceFactory.sharedSpotifyStore
                    )
                }
                Button("ログアウト") {
                    Task {
                        await spotifyStore.clearSessionData()
                    }
                }
                .disabled(!spotifyStore.isLoggedIn)
            }
        }
        settingsRow("注意") {
            Text("Spotify Web Player の DOM 構造変更で取得や再生が失敗する場合があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generationTTSSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Gemini TTS") {
                TTSCredentialSetsEditor(credentialSets: $draftSettings.ttsCredentialSets)
            }

            settingsGroup("台本生成 CLI") {
                settingsRow("CLI") {
                    Picker("CLI", selection: $draftSettings.scriptCLIKind) {
                        ForEach(ScriptCLIKind.allCases) { cliKind in
                            Text(cliKind.displayName).tag(cliKind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                settingsRow("CLI モデル") {
                    TextField("未指定なら CLI の既定値", text: $draftSettings.scriptCLIModel)
                        .textFieldStyle(.roundedBorder)
                }

                if draftSettings.scriptCLIKind == .custom {
                    settingsRow("実行ファイル") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("mycli または /opt/bin/mycli", text: $draftSettings.customCLIExecutable)
                                .textFieldStyle(.roundedBorder)
                            Text("コマンド名またはフルパス。空の場合は台本生成に失敗します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    settingsRow("引数") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $customArgsText)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 90)
                                .border(Color(nsColor: .separatorColor))
                            Text("1 行 1 引数。{prompt} をプロンプトに置換します。\n例: -p\n{prompt}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    settingsRow("モデル引数") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $customModelArgsText)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 60)
                                .border(Color(nsColor: .separatorColor))
                            Text("「CLI モデル」指定時のみ末尾に追加。{model} をモデル名に置換。\n例: --model\n{model}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var recordingSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("録音設定") {
                settingsRow("録音出力先") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "未入力なら ~/Music/AgentBooth/",
                            text: $draftSettings.recordingOutputDirectory
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("空欄の場合は ~/Music/AgentBooth/ に保存されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingsGroup("注意事項") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("録音はシステム音声キャプチャ（ScreenCaptureKit）を使用します。", systemImage: "info.circle")
                    Label("初回使用時に「画面収録」の権限確認ダイアログが表示されます。", systemImage: "lock.shield")
                    Label("録音中は他のアプリの通知音なども混入します。録音時はおやすみモードの使用を推奨します。", systemImage: "moon.fill")
                    Label("ファイル形式: M4A (AAC 192kbps, 48kHz stereo)", systemImage: "music.note")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(localizedString(title))
                .font(.headline)
        }
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(localizedString(title))
                .frame(width: 170, alignment: .trailing)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localizedString(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func profileNameBinding(_ profileID: UUID) -> Binding<String> {
        Binding(
            get: {
                settingsStore.showProfiles.first(where: { $0.id == profileID })?.name ?? ""
            },
            set: { newValue in
                do {
                    try settingsStore.renameProfile(id: profileID, name: newValue)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func selectProfile(_ profileID: UUID) {
        do {
            try settingsStore.selectProfile(profileID)
            reloadSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProfile() {
        do {
            try settingsStore.createProfile(named: newProfileName)
            newProfileName = ""
            reloadSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateProfile(_ profileID: UUID) {
        do {
            try settingsStore.duplicateProfile(id: profileID)
            reloadSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProfile(_ profileID: UUID) {
        do {
            try settingsStore.deleteProfile(id: profileID)
            reloadSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func optionalTextBinding(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: {
                draftSettings[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draftSettings[keyPath: keyPath] = trimmedValue.isEmpty ? nil : newValue
            }
        )
    }

    private func timeBandPresetBinding(_ timeBand: TimeBand) -> Binding<String> {
        Binding(
            get: {
                draftSettings.directionSettings.timeBasedPresets[timeBand] ?? ""
            },
            set: { newValue in
                let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedValue.isEmpty {
                    draftSettings.directionSettings.timeBasedPresets.removeValue(forKey: timeBand)
                } else {
                    draftSettings.directionSettings.timeBasedPresets[timeBand] = newValue
                }
            }
        )
    }

    private func timeBandPresetPlaceholder(_ timeBand: TimeBand) -> String {
        String(format: String(localized: "例: %@らしい話し方"), timeBand.displayName)
    }

    private func playbackBalanceField<Value>(
        placeholder: String,
        value: Binding<Value>,
        formatter: NumberFormatter,
        description: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TextField(localizedString(placeholder), value: value, formatter: formatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140, height: 28)

            Text(localizedString(description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 28, alignment: .leading)
        }
    }

    private func audioAssetSourceRow(
        title: String,
        source: Binding<AudioAssetSource>
    ) -> some View {
        settingsRow(title) {
            HStack(spacing: 10) {
                audioAssetSelectionLabel(source.wrappedValue)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("選択") {
                    selectAudioAsset(for: source)
                }

                Button("クリア") {
                    source.wrappedValue.path = ""
                }
                .disabled(source.wrappedValue.path.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func audioAssetSelectionLabel(_ source: AudioAssetSource) -> some View {
        if source.path.isEmpty {
            Text("未選択")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func volumeSlider(value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: 0...1)
                .frame(width: 220)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }

    private var decimalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }

    private func reloadSettings() {
        draftSettings = settingsStore.currentSettings
        customArgsText = draftSettings.customCLIArguments.joined(separator: "\n")
        customModelArgsText = draftSettings.customCLIModelArguments.joined(separator: "\n")
        errorMessage = nil
    }

    private func saveSettings() {
        do {
            try settingsStore.saveSettings(draftSettings)
            ytStore.setUserAgent(draftSettings.youtubeMusicUserAgent)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectAudioAsset(for source: Binding<AudioAssetSource>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = audioAssetPanelDirectory(for: source.wrappedValue)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        source.wrappedValue.path = url.path
        source.wrappedValue.kind = isDirectoryURL(url) ? .directory : .file
    }

    private func audioAssetPanelDirectory(for source: AudioAssetSource) -> URL? {
        let trimmedPath = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        var candidateURL = URL(fileURLWithPath: trimmedPath)
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidateURL
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                return nil
            }
            candidateURL = parentURL
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

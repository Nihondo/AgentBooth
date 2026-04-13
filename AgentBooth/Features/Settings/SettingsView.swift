import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case music
    case program
    case tts
    case recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "サービス"
        case .music:
            return "楽曲の再生"
        case .program:
            return "番組情報"
        case .tts:
            return "テキスト読み上げ"
        case .recording:
            return "録音"
        }
    }

    var systemImageName: String {
        switch self {
        case .general:
            return "slider.horizontal.3"
        case .music:
            return "music.note.list"
        case .program:
            return "dot.radiowaves.left.and.right"
        case .tts:
            return "waveform"
        case .recording:
            return "record.circle"
        }
    }

    var descriptionText: String {
        switch self {
        case .general:
            return "音楽サービスの設定を行います。"
        case .music:
            return "楽曲の再生バランスを設定します。"
        case .program:
            return "番組名やパーソナリティ名を設定します。"
        case .tts:
            return "Gemini TTS と台本生成 CLI の設定を行います。"
        case .recording:
            return "番組のシステム音声キャプチャ録音の設定を行います。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    @State private var draftSettings = AppSettings()
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var errorMessage: String?
    @ObservedObject private var ytStore = LiveAppServiceFactory.sharedYouTubeMusicStore
    @ObservedObject private var spotifyStore = LiveAppServiceFactory.sharedSpotifyStore

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.systemImageName)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            detailView
        }
        .frame(minWidth: 860, minHeight: 620)
        .navigationTitle("AgentBooth 設定")
        .onAppear {
            draftSettings = settingsStore.currentSettings
            ytStore.setUserAgent(settingsStore.currentSettings.youtubeMusicUserAgent)
            Task { @MainActor in
                await spotifyStore.refreshLoginStatus()
            }
        }
        .onChange(of: draftSettings) {
            saveSettings()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let category = selectedCategory ?? .general

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title)
                        .font(.title2.weight(.semibold))
                    Text(category.descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        case .general:
            generalSettingsView
        case .music:
            musicSettingsView
        case .program:
            programSettingsView
        case .tts:
            ttsSettingsView
        case .recording:
            recordingSettingsView
        }
    }

    private var generalSettingsView: some View {
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

    private var musicSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        description: "トーク終了前に次曲を出し始める秒数"
                    )
                }

                settingsRow("トーク先行開始秒数") {
                    playbackBalanceField(
                        placeholder: "10",
                        value: $draftSettings.volumeSettings.fadeEarlySeconds,
                        formatter: numberFormatter,
                        description: "曲終了前にトークを再開する秒数"
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

    private var programSettingsView: some View {
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

            settingsGroup("番組情報") {
                settingsRow("番組名") {
                    TextField("AgentBooth Radio", text: $draftSettings.radioShowSettings.showName)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("周波数・チャンネル名") {
                    TextField("例: 77.5 FM", text: $draftSettings.radioShowSettings.frequency)
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

            settingsGroup("ディレクション") {
                settingsRow("シーン・セリフの指示") {
                    TextField("例: 深夜帯、静かに話す", text: $draftSettings.directionSettings.sceneDirection, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...)
                }
            }

        }
    }

    private var ttsSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Gemini TTS") {
                settingsRow("API Key") {
                    SecureField("Gemini API Key", text: $draftSettings.geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("TTS モデル") {
                    TextField("gemini-2.5-flash-preview-tts", text: $draftSettings.geminiTTSModel)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("フォールバックモデル") {
                    TextField("gemini-2.5-pro-preview-tts", text: $draftSettings.geminiTTSFallbackModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

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

            settingsGroup("台本生成 CLI") {
                settingsRow("CLI") {
                    Picker("CLI", selection: $draftSettings.scriptCLIKind) {
                        ForEach(ScriptCLIKind.allCases) { cliKind in
                            Text(cliKind.rawValue).tag(cliKind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                settingsRow("CLI モデル") {
                    TextField("未指定なら CLI の既定値", text: $draftSettings.scriptCLIModel)
                        .textFieldStyle(.roundedBorder)
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
            Text(title)
                .font(.headline)
        }
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .frame(width: 170, alignment: .trailing)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playbackBalanceField<Value>(
        placeholder: String,
        value: Binding<Value>,
        formatter: NumberFormatter,
        description: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TextField(placeholder, value: value, formatter: formatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140, height: 28)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 28, alignment: .leading)
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
}

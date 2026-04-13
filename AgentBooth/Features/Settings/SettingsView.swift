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
            return "一般"
        case .music:
            return "音楽"
        case .program:
            return "番組"
        case .tts:
            return "TTS"
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
            return "アプリ全体の既定値を設定します。"
        case .music:
            return "音楽サービス制御と再生バランスを設定します。"
        case .program:
            return "番組名やパーソナリティ名を設定します。"
        case .tts:
            return "Gemini TTS と台本生成 CLI を設定します。"
        case .recording:
            return "番組のシステム音声キャプチャ録音の設定をします。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    @State private var draftSettings = AppSettings()
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var errorMessage: String?
    @State private var isSaved = false
    @ObservedObject private var ytStore = LiveAppServiceFactory.sharedYouTubeMusicStore

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

                Divider()

                HStack(spacing: 12) {
                    Button("現在の設定を読み直す") {
                        reloadSettings()
                    }

                    Button("保存") {
                        saveSettings()
                    }
                    .keyboardShortcut("s", modifiers: [.command])

                    if isSaved {
                        Text("保存しました")
                            .foregroundStyle(.green)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
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
    }

    private var musicSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("YouTube Music") {
                youtubeMusicLoginRow
            }

            settingsGroup("再生バランス") {
                settingsRow("通常音量") {
                    TextField("100", value: $draftSettings.volumeSettings.normalVolume, formatter: numberFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                settingsRow("トーク時音量") {
                    TextField("25", value: $draftSettings.volumeSettings.talkVolume, formatter: numberFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                settingsRow("フェード秒数") {
                    TextField("5.0", value: $draftSettings.volumeSettings.fadeDuration, formatter: decimalFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                settingsRow("曲終了前秒数") {
                    TextField("10", value: $draftSettings.volumeSettings.fadeEarlySeconds, formatter: numberFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                settingsRow("BGM 先行開始秒数") {
                    TextField("10", value: $draftSettings.volumeSettings.musicLeadSeconds, formatter: decimalFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                settingsRow("最大再生秒数") {
                    TextField("0（制限なし）", value: $draftSettings.volumeSettings.maxPlaybackDurationSeconds, formatter: numberFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
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
        isSaved = false
    }

    private func saveSettings() {
        do {
            try settingsStore.saveSettings(draftSettings)
            errorMessage = nil
            isSaved = true
        } catch {
            errorMessage = error.localizedDescription
            isSaved = false
        }
    }
}

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controlRow
            Divider()
            statusInfoRow
            recordingInfoRow
            Divider()
            trackListSection
            if viewModel.radioState.isRunning, let track = viewModel.radioState.currentTrack {
                NowPlayingBar(
                    track: track,
                    playbackPosition: viewModel.radioState.currentPlaybackPosition,
                    volume: viewModel.radioState.volume,
                    trackIndex: viewModel.radioState.trackIndex,
                    trackCount: viewModel.radioState.playlistTrackCount
                )
            }
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: WindowIdentifier.settings)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            }
        }
        .task {
            await viewModel.loadPlaylists()
        }
    }

    private var controlRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Picker("サービス", selection: Binding(
                get: { viewModel.selectedService },
                set: { viewModel.selectService($0) }
            )) {
                ForEach(viewModel.availableServices) { service in
                    Text(service.displayName).tag(service)
                }
            }
            .frame(width: 180)
            .disabled(viewModel.radioState.isRunning)

            Picker("プレイリスト", selection: Binding(
                get: { viewModel.selectedPlaylistName },
                set: { viewModel.selectPlaylist($0) }
            )) {
                if viewModel.availablePlaylists.isEmpty {
                    Text("プレイリストなし").tag("")
                } else {
                    ForEach(viewModel.availablePlaylists, id: \.self) { playlistName in
                        Text(playlistName).tag(playlistName)
                    }
                }
            }
            .frame(width: 260)
            .disabled(viewModel.radioState.isRunning)

            Button {
                let isTestMode = NSEvent.modifierFlags.contains(.command)
                viewModel.handlePrimaryControl(isTestMode: isTestMode)
            } label: {
                Image(systemName: viewModel.primaryControlState.buttonSystemImageName)
                    .frame(width: 18, height: 18)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(viewModel.primaryControlState.buttonLabelText)
            .help("再生")
            .disabled(
                viewModel.isRecordingSession
                || (viewModel.primaryControlState == .start && !viewModel.canStart)
            )

            Button {
                viewModel.stopShow()
            } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("停止")
            .help("停止")
            .disabled(!viewModel.radioState.isRunning)

            Button {
                viewModel.startShowWithRecording()
            } label: {
                Image(systemName: viewModel.radioState.isRecording ? "record.circle.fill" : "record.circle")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("録音して再生")
            .help("番組をシステム音声キャプチャで録音しながら開始します。録音中は他のアプリの音も混入するため、おやすみモードの使用を推奨します。")
            .disabled(!viewModel.canStart)
        }
    }

    /// トラック一覧テーブル
    private var trackListSection: some View {
        let effectiveState: TrackListState = viewModel.radioState.isRunning
            ? .loaded(viewModel.displayTracks)
            : viewModel.previewTrackListState

        return TrackListView(
            tracks: viewModel.displayTracks,
            currentPlayingTrackID: viewModel.currentPlayingTrackID,
            trackListState: effectiveState,
            isRadioRunning: viewModel.radioState.isRunning,
            currentPlaybackPosition: viewModel.radioState.currentPlaybackPosition
        )
    }

    /// ステータスメッセージとスピナーを表示する行
    private var statusInfoRow: some View {
        Group {
            if viewModel.radioState.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.radioState.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } else if !viewModel.radioState.statusMessage.isEmpty {
                Text(viewModel.radioState.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let error = viewModel.radioState.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 録音完了URLを表示する行
    private var recordingInfoRow: some View {
        Group {
            if let recordingURL = viewModel.radioState.recordingOutputURL, !viewModel.radioState.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("録音保存先: ")
                        .foregroundStyle(.secondary)
                    Button(recordingURL.lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
                    }
                    .buttonStyle(.link)
                    .help(recordingURL.path)
                }
                .font(.subheadline)
            }
        }
    }

}

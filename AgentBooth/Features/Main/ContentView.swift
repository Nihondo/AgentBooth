import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controlRow
            Divider()
            statusSection
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 420)
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
                viewModel.handlePrimaryControl()
            } label: {
                Image(systemName: viewModel.primaryControlState.buttonSystemImageName)
                    .frame(width: 18, height: 18)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(viewModel.primaryControlState.buttonLabelText)
            .help(viewModel.primaryControlState.buttonLabelText)
            .disabled(viewModel.primaryControlState == .start && !viewModel.canStart)

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
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("状態")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                statusRow("Phase", value: viewModel.radioState.phase.rawValue)
                statusRow("Status", value: viewModel.radioState.statusMessage.isEmpty ? "-" : viewModel.radioState.statusMessage)
                statusRow("Playlist", value: viewModel.radioState.playlistName.isEmpty ? "-" : viewModel.radioState.playlistName)
                statusRow("Track", value: viewModel.radioState.currentTrack?.displayText ?? "-")
                statusRow("Running", value: viewModel.radioState.isRunning ? "true" : "false")
                statusRow("Paused", value: viewModel.radioState.isPaused ? "true" : "false")
                statusRow("Volume", value: "\(viewModel.radioState.volume)")
            }

            if let errorMessage = viewModel.radioState.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if !viewModel.radioState.upcomingTracks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upcoming Tracks")
                        .font(.headline)
                    ForEach(viewModel.radioState.upcomingTracks.prefix(5)) { track in
                        Text(track.displayText)
                            .font(.body.monospaced())
                    }
                }
            }
        }
    }

    private func statusRow(_ labelText: String, value: String) -> some View {
        GridRow {
            Text(labelText)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

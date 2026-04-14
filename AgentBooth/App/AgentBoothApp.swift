import AppKit
import SwiftUI

enum WindowIdentifier {
    static let main = "main"
    static let settings = "settings"
}

/// アプリケーションデリゲート。メインウィンドウを閉じたらアプリを終了する。
private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func handleWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // SwiftUI が Window シーンに設定する identifier はシーン ID と一致する
        if window.identifier?.rawValue == WindowIdentifier.main {
            NSApp.terminate(nil)
        }
    }
}

private struct AgentBoothCommands: Commands {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                openWindow(id: WindowIdentifier.settings)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("AgentBooth 設定…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(after: .newItem) {
            Divider()
            // ウィンドウの再生/一時停止ボタンと同一の条件・動作
            Button {
                viewModel.handlePrimaryControl()
            } label: {
                Label(
                    viewModel.primaryControlState.buttonLabelText,
                    systemImage: viewModel.primaryControlState.buttonSystemImageName
                )
            }
            .keyboardShortcut(" ", modifiers: [])
            .disabled(
                viewModel.isRecordingSession
                    || (viewModel.primaryControlState == .start && !viewModel.canStart)
            )
            // ウィンドウの停止ボタンと同一の条件・動作
            Button {
                viewModel.stopShow()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!viewModel.radioState.isRunning)
            // ウィンドウの録音ボタンと同一の条件・動作
            Button {
                viewModel.startShowWithRecording()
            } label: {
                Label("録音して開始", systemImage: "record.circle")
            }
            .keyboardShortcut("r", modifiers: [.control, .command])
            .disabled(!viewModel.canStart)
            Divider()
        }
    }
}

@main
struct AgentBoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var mainViewModel: MainViewModel

    init() {
        let settingsStore = AppSettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _mainViewModel = StateObject(
            wrappedValue: MainViewModel(
                settingsStore: settingsStore,
                serviceFactory: LiveAppServiceFactory()
            )
        )
    }

    var body: some Scene {
        Window("AgentBooth", id: WindowIdentifier.main) {
            ContentView(viewModel: mainViewModel)
                .onAppear {
                    LiveAppServiceFactory.sharedYouTubeMusicStore.setUserAgent(
                        settingsStore.currentSettings.youtubeMusicUserAgent
                    )
                    LiveAppServiceFactory.sharedSpotifyStore.setUserAgent(defaultSpotifyUserAgent)
                    Task { @MainActor in
                        await LiveAppServiceFactory.sharedSpotifyStore.refreshLoginStatus()
                    }
                }
        }
        .commands {
            AgentBoothCommands(viewModel: mainViewModel)
        }

        Window("AgentBooth 設定", id: WindowIdentifier.settings) {
            SettingsView(settingsStore: settingsStore)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentSize)
    }
}

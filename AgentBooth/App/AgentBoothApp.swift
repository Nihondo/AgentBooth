import SwiftUI

enum WindowIdentifier {
    static let settings = "settings"
}

private struct AgentBoothCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("AgentBooth 設定…") {
                openWindow(id: WindowIdentifier.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

@main
struct AgentBoothApp: App {
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
        WindowGroup {
            ContentView(viewModel: mainViewModel)
                .onAppear {
                    LiveAppServiceFactory.sharedYouTubeMusicStore.setUserAgent(
                        settingsStore.currentSettings.youtubeMusicUserAgent
                    )
                }
        }
        .commands {
            AgentBoothCommands()
        }

        Window("AgentBooth 設定", id: WindowIdentifier.settings) {
            SettingsView(settingsStore: settingsStore)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentSize)
    }
}

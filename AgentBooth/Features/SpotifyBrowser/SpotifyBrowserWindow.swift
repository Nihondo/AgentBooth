import AppKit
import SwiftUI

/// Spotify ログインウィンドウを管理する。
@MainActor
final class SpotifyBrowserWindowController {
    static let shared = SpotifyBrowserWindowController()

    private var window: NSWindow?
    private var windowDelegate: WindowDelegate?

    private init() {}

    /// ログインウィンドウを開く。
    func open(store: SpotifyWebViewStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SpotifyLoginViewModel(store: store)
        let browserView = SpotifyBrowserView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: browserView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Spotify ログイン"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 1100, height: 760)
        window.center()
        window.isReleasedWhenClosed = false
        let windowDelegate = WindowDelegate(controller: self)
        window.delegate = windowDelegate
        self.windowDelegate = windowDelegate
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// ログインウィンドウを閉じる。
    func close() {
        window?.close()
        window = nil
        windowDelegate = nil
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private weak var controller: SpotifyBrowserWindowController?

        init(controller: SpotifyBrowserWindowController) {
            self.controller = controller
        }

        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in
                controller?.window = nil
                controller?.windowDelegate = nil
            }
        }
    }
}

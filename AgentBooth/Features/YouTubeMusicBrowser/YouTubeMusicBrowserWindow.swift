// MARK: - YouTubeMusicBrowserWindow.swift
// YouTube Music ログイン用ウィンドウのライフサイクルを管理する。
// AppKit の NSWindow をラップして SwiftUI から開閉できるようにする。

import AppKit
import SwiftUI

/// YouTube Music ログインウィンドウを管理するシングルトン
@MainActor
final class YouTubeMusicBrowserWindowController {
    static let shared = YouTubeMusicBrowserWindowController()

    private var window: NSWindow?

    private init() {}

    /// ウィンドウを開く（既に開いていればフォーカスのみ）
    func open(store: YouTubeMusicWebViewStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = YouTubeMusicLoginViewModel(store: store)
        let browserView = YouTubeMusicBrowserView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: browserView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "YouTube Music ログイン"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 960, height: 700))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = WindowDelegate(controller: self)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    /// ウィンドウを閉じる
    func close() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private weak var controller: YouTubeMusicBrowserWindowController?

        init(controller: YouTubeMusicBrowserWindowController) {
            self.controller = controller
        }

        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in
                controller?.window = nil
            }
        }
    }
}

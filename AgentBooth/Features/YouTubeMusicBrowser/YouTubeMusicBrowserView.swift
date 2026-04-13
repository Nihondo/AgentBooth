// MARK: - YouTubeMusicBrowserView.swift
// YouTube Music ログイン用の内蔵ブラウザビュー。
// WKWebView を NSViewRepresentable でラップし、ログイン状態をオーバーレイ表示する。

import SwiftUI
import WebKit

struct YouTubeMusicBrowserView: View {
    @ObservedObject var viewModel: YouTubeMusicLoginViewModel

    var body: some View {
        VStack(spacing: 0) {
            // ステータスバー
            statusBar

            // WebView 本体
            ZStack {
                YouTubeMusicWebViewRepresentable(store: viewModel.webViewStore)

                // ポップアップウィンドウ（OAuth ログイン）
                if let popup = viewModel.webViewStore.popupWebView {
                    PopupWebViewRepresentable(webView: popup)
                        .overlay(alignment: .topLeading) {
                            Button {
                                viewModel.webViewStore.closePopupWebView()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            // ログイン状態インジケーター
            Circle()
                .fill(viewModel.isLoggedIn ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if viewModel.isLoggedIn {
                Button("ログアウト") {
                    Task { await viewModel.logout() }
                }
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - ポップアップ WebView

/// OAuth ポップアップ用の WebView を SwiftUI に埋め込む
private struct PopupWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

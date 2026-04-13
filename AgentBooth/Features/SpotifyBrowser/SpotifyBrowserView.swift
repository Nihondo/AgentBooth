import SwiftUI
import WebKit

/// Spotify ログイン用ブラウザビュー。
struct SpotifyBrowserView: View {
    @ObservedObject var viewModel: SpotifyLoginViewModel

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            ZStack {
                SpotifyWebViewRepresentable(store: viewModel.webViewStore)

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
        .frame(minWidth: 1100, minHeight: 760)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
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

private struct PopupWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

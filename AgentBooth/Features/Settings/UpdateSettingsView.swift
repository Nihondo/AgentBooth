// MARK: - UpdateSettingsView.swift
// アップデート設定タブ。Sparkle によるアップデートチェック状態の表示と手動チェックを提供する。

import SwiftUI

/// アップデート設定タブ UI
struct UpdateSettingsView: View {

    @ObservedObject private var updateController = AppUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(String(localized: "バージョン情報")) {
                settingsRow(String(localized: "現在のバージョン")) {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }

                settingsRow(String(localized: "最終チェック")) {
                    Text(lastCheckedText)
                        .foregroundStyle(.secondary)
                }
            }

            settingsGroup(String(localized: "アップデート")) {
                settingsRow("") {
                    Button(String(localized: "今すぐ確認")) {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.canCheckForUpdates)
                }

                settingsRow("") {
                    Toggle(
                        String(localized: "自動的にアップデートを確認する"),
                        isOn: Binding(
                            get: { updateController.automaticChecksEnabled },
                            set: { updateController.setAutomaticChecksEnabled($0) }
                        )
                    )
                }
            }

            settingsGroup(String(localized: "リリース情報")) {
                settingsRow("") {
                    Link(destination: URL(string: "https://github.com/Nihondo/AgentBooth/releases")!) {
                        HStack {
                            Text(String(localized: "リリースページを開く"))
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var lastCheckedText: String {
        guard let date = updateController.lastUpdateCheckDate else {
            return String(localized: "未確認")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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
}

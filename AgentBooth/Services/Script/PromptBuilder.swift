import Foundation

enum PromptBuilder {
    static func buildOpeningPrompt(tracks: [TrackInfo], settings: AppSettings) -> String {
        let firstTrack = tracks[0]
        return """
        あなたはラジオ番組の台本作家です。
        ラジオ番組の冒頭オープニングトークを2名の掛け合いで作成してください。
        このオープニングは1曲目のイントロを兼ねます。番組挨拶、プレイリスト紹介、1曲目への導入の流れで構成してください。

        \(showInfoBlock(settings: settings))
        【本日のプレイリスト】
        \(trackListBlock(tracks))

        【1曲目】
        - 曲名: \(firstTrack.name)
        - アーティスト: \(firstTrack.artist)
        - アルバム: \(firstTrack.album)

        【登場人物】
        \(castBlock(settings: settings))

        \(directionBlock(settings: settings))
        【ルール】
        - 会話は6〜10ターン程度
        - 番組の開始挨拶から始める
        - 今日のプレイリストの傾向や雰囲気を自然に紹介する
        - リスナーへの呼びかけや時間帯に合った挨拶を入れる
        - 後半で1曲目の紹介に自然につなげる
        - 曲の豆知識やアーティストのエピソードを含めてもよい
        - 読みが不明な場合や、話題の検索にWeb検索を活用してもよい
        - speaker に使ってよい値は male と female のみ
        \(summaryRuleLines())
        - text の中で ASCII の二重引用符は使わず、日本語のカギ括弧を使う
        - 最後は曲を流す合図で締める
        - JSONのみ出力し、余計な説明は不要

        【出力形式】
        \(formatExample())
        """
    }

    static func buildIntroPrompt(track: TrackInfo, settings: AppSettings, continuityNote: String?) -> String {
        return """
        あなたはラジオ番組の台本作家です。
        再生中の楽曲に途中から重ねる、ラジオパーソナリティ2名のイントロトークを作成してください。

        【楽曲情報】
        - 曲名: \(track.name)
        - アーティスト: \(track.artist)
        - アルバム: \(track.album)
        \(continuityBlock(continuityNote))
        【登場人物】
        \(castBlock(settings: settings))

        \(directionBlock(settings: settings))
        【ルール】
        - 会話は4〜8ターン程度
        - 曲がすでに流れている前提で、楽曲紹介や聴きどころを自然に話す
        - 曲の豆知識、アーティストのエピソード、アルバムの背景など自然な雑談を含める
        - 読みが不明な場合や、話題の検索にWeb検索を活用してもよい
        - speaker に使ってよい値は male と female のみ
        - 2人の掛け合いにし、片方だけが続かないようにする
        - 重複しそうな話題は避ける
        \(summaryRuleLines())
        - text の中で ASCII の二重引用符は使わず、日本語のカギ括弧を使う
        - 最後は楽曲の続きを聴かせる流れで締める
        - JSONのみ出力し、余計な説明は不要

        【出力形式】
        \(formatExample())
        """
    }

    static func buildTransitionPrompt(
        currentTrack: TrackInfo,
        nextTrack: TrackInfo,
        settings: AppSettings,
        continuityNote: String?
    ) -> String {
        return """
        あなたはラジオ番組の台本作家です。
        前の曲の感想から次の曲紹介まで、ラジオパーソナリティ2名によるひと続きの自然な掛け合いを作成してください。

        【前の曲】
        - 曲名: \(currentTrack.name)
        - アーティスト: \(currentTrack.artist)
        - アルバム: \(currentTrack.album)

        【次の曲】
        - 曲名: \(nextTrack.name)
        - アーティスト: \(nextTrack.artist)
        - アルバム: \(nextTrack.album)
        \(continuityBlock(continuityNote))
        【登場人物】
        \(castBlock(settings: settings))

        \(directionBlock(settings: settings))
        【ルール】
        - 会話は6〜10ターン
        - 前半は前の曲の感想や振り返り
        - 後半は次の曲の紹介と導入
        - 読みが不明な場合や、話題の検索にWeb検索を活用してもよい
        - 話題の切り替えを自然にする
        - speaker に使ってよい値は male と female のみ
        \(summaryRuleLines())
        - text の中で ASCII の二重引用符は使わない
        - 最後は曲を流す合図で締める
        - JSONのみ出力し、余計な説明は不要

        【出力形式】
        \(formatExample())
        """
    }

    static func buildClosingPrompt(tracks: [TrackInfo], settings: AppSettings) -> String {
        return """
        あなたはラジオ番組の台本作家です。
        ラジオ番組のクロージングトークを2名の掛け合いで作成してください。

        \(showInfoBlock(settings: settings))
        【本日お届けした曲】
        \(trackListBlock(tracks))

        【登場人物】
        \(castBlock(settings: settings))

        \(directionBlock(settings: settings))
        【ルール】
        - 会話は4〜8ターン程度
        - 今日の放送の振り返りを含める
        - リスナーへの感謝と次回への期待を入れる
        - speaker に使ってよい値は male と female のみ
        \(summaryRuleLines())
        - text の中で ASCII の二重引用符は使わず、日本語のカギ括弧を使う
        - 最後の挨拶で番組を締める
        - JSONのみ出力し、余計な説明は不要
        【出力形式】
        \(formatExample())
        """
    }

    private static func castBlock(settings: AppSettings) -> String {
        [
            "- \(settings.personalitySettings.maleHostName)（男性パーソナリティ）: speaker=\"male\"",
            "- \(settings.personalitySettings.femaleHostName)（女性パーソナリティ）: speaker=\"female\"",
        ].joined(separator: "\n")
    }

    private static func formatExample() -> String {
        """
        {
          "dialogues": [
            {"speaker": "male", "text": "発話内容"},
            {"speaker": "female", "text": "発話内容"}
          ],
          "summaryBullets": [
            "触れた話題の要点",
            "次回は避けたい観点"
          ]
        }
        """
    }

    private static func summaryRuleLines() -> String {
        """
        - summaryBullets には今回触れた話題・観点・エピソードを 2〜4 件の短い箇条書きで入れる
        - summaryBullets は次回の重複回避メモとして使うため、自然な台詞そのものではなく要点だけを書く
        - summaryBullets の各項目は 1 行で簡潔にまとめ、長文の要約は避ける
        """
    }

    private static func continuityBlock(_ continuityNote: String?) -> String {
        guard let continuityNote, !continuityNote.isEmpty else {
            return ""
        }
        return """
        【直前のオンエアで既に触れた内容】
        \(continuityNote)

        """
    }

    private static func directionBlock(settings: AppSettings) -> String {
        let direction = settings.directionSettings.sceneDirection
        guard !direction.isEmpty else { return "" }
        return "【シーン・話し方などのディレクション】\n        \(direction)\n        "
    }

    private static func showInfoBlock(settings: AppSettings) -> String {
        var lines: [String] = []
        if !settings.radioShowSettings.showName.isEmpty {
            lines.append("- 番組名: \(settings.radioShowSettings.showName)")
        }
        if !settings.radioShowSettings.frequency.isEmpty {
            lines.append("- 周波数: \(settings.radioShowSettings.frequency)")
        }
        guard !lines.isEmpty else {
            return ""
        }
        return "【番組情報】\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func trackListBlock(_ tracks: [TrackInfo]) -> String {
        tracks.enumerated()
            .map { indexValue, track in
                "  \(indexValue + 1). \(track.name) / \(track.artist)"
            }
            .joined(separator: "\n")
    }
}

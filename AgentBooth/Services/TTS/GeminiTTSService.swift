import Foundation

struct GeminiRetryPolicy {
    let dailyQuotaThresholdSeconds: Double = 3600

    func parseRetryDelay(from bodyText: String) -> Double {
        if let seconds = matchFirstInteger(pattern: "\"retryDelay\"\\s*:\\s*\"(\\d+)s\"", text: bodyText) {
            return seconds
        }

        let pattern = "retry in (\\d+)h(\\d+)m"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let range = NSRange(bodyText.startIndex..., in: bodyText)
        guard let match = regex.firstMatch(in: bodyText, range: range),
              let hourRange = Range(match.range(at: 1), in: bodyText),
              let minuteRange = Range(match.range(at: 2), in: bodyText) else {
            return 0
        }

        let hourValue = Double(bodyText[hourRange]) ?? 0
        let minuteValue = Double(bodyText[minuteRange]) ?? 0
        return (hourValue * 3600) + (minuteValue * 60)
    }

    func isRateLimited(statusCode: Int, bodyText: String) -> Bool {
        statusCode == 429 || bodyText.contains("RESOURCE_EXHAUSTED") || bodyText.contains("retryDelay")
    }

    func isDailyQuotaExhausted(bodyText: String) -> Bool {
        parseRetryDelay(from: bodyText) > dailyQuotaThresholdSeconds
    }

    private func matchFirstInteger(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[valueRange])
    }
}

enum GeminiTTSServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse(String)
    case httpError(Int, String)
    case dailyQuotaExceeded

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "Gemini API Key が未設定です。")
        case .invalidResponse(let detail):
            return String(format: String(localized: "Gemini TTS の応答を解釈できませんでした。%@"), detail)
        case .httpError(let statusCode, let bodyText):
            return "Gemini TTS request failed with status \(statusCode): \(bodyText)"
        case .dailyQuotaExceeded:
            return String(localized: "Gemini TTS の日次クォータに達しました。")
        }
    }
}

private struct GeminiGenerateRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig

    enum CodingKeys: String, CodingKey {
        case contents
        case generationConfig = "generationConfig"
    }
}

private struct GeminiContent: Encodable {
    let parts: [GeminiTextPart]
}

private struct GeminiTextPart: Encodable {
    let text: String
}

private struct GeminiGenerationConfig: Encodable {
    let responseModalities: [String]
    let speechConfig: GeminiSpeechConfig
}

private struct GeminiSpeechConfig: Encodable {
    let multiSpeakerVoiceConfig: GeminiMultiSpeakerVoiceConfig
}

private struct GeminiMultiSpeakerVoiceConfig: Encodable {
    let speakerVoiceConfigs: [GeminiSpeakerVoiceConfig]
}

private struct GeminiSpeakerVoiceConfig: Encodable {
    let speaker: String
    let voiceConfig: GeminiVoiceConfig
}

private struct GeminiVoiceConfig: Encodable {
    let prebuiltVoiceConfig: GeminiPrebuiltVoiceConfig
}

private struct GeminiPrebuiltVoiceConfig: Encodable {
    let voiceName: String
}

private struct GeminiGenerateResponse: Decodable {
    let candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    let content: GeminiGeneratedContent
}

private struct GeminiGeneratedContent: Decodable {
    let parts: [GeminiGeneratedPart]
}

private struct GeminiGeneratedPart: Decodable {
    let inlineData: GeminiInlineData?
}

private struct GeminiInlineData: Decodable {
    let data: String
    let mimeType: String?
}

/// Talks to the Gemini REST API and converts PCM data to WAV.
actor GeminiTTSService: TTSService {
    private let session: URLSession
    private let retryPolicy = GeminiRetryPolicy()
    private let encoder = JSONEncoder()
    private var nextCallDate = Date.distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    func synthesize(dialogues: [DialogueLine], settings: AppSettings) async throws -> TTSResult {
        guard !settings.geminiAPIKey.isEmpty else {
            throw GeminiTTSServiceError.missingAPIKey
        }

        do {
            let wavData = try await requestWAV(
                dialogues: dialogues,
                settings: settings,
                modelName: settings.geminiTTSModel,
                skipWait: false
            )
            return TTSResult(wavData: wavData, modelUsed: settings.geminiTTSModel)
        } catch GeminiTTSServiceError.httpError(let statusCode, let bodyText)
            where retryPolicy.isRateLimited(statusCode: statusCode, bodyText: bodyText)
            && !settings.geminiTTSFallbackModel.isEmpty
            && settings.geminiTTSFallbackModel != settings.geminiTTSModel {
            // 主モデルがレート制限（日次制限含む）→ 即座に副モデルで再試行
            do {
                let wavData = try await requestWAV(
                    dialogues: dialogues,
                    settings: settings,
                    modelName: settings.geminiTTSFallbackModel,
                    skipWait: true
                )
                return TTSResult(wavData: wavData, modelUsed: settings.geminiTTSFallbackModel)
            } catch GeminiTTSServiceError.httpError(_, let fbBody)
                where retryPolicy.isDailyQuotaExhausted(bodyText: fbBody) {
                // 副モデルも日次クォータ超過 → 両モデルとも限界
                throw GeminiTTSServiceError.dailyQuotaExceeded
            }
        }
    }

    private func requestWAV(
        dialogues: [DialogueLine],
        settings: AppSettings,
        modelName: String,
        skipWait: Bool
    ) async throws -> Data {
        if !skipWait {
            let waitInterval = nextCallDate.timeIntervalSinceNow
            if waitInterval > 0 {
                try await Task.sleep(nanoseconds: UInt64(waitInterval * 1_000_000_000))
            }
        }
        nextCallDate = Date().addingTimeInterval(60)

        let requestBody = GeminiGenerateRequest(
            contents: [
                GeminiContent(parts: [GeminiTextPart(text: makeTTSInput(dialogues: dialogues, settings: settings))]),
            ],
            generationConfig: GeminiGenerationConfig(
                responseModalities: ["AUDIO"],
                speechConfig: GeminiSpeechConfig(
                    multiSpeakerVoiceConfig: GeminiMultiSpeakerVoiceConfig(
                        speakerVoiceConfigs: [
                            GeminiSpeakerVoiceConfig(
                                speaker: "Male",
                                voiceConfig: GeminiVoiceConfig(
                                    prebuiltVoiceConfig: GeminiPrebuiltVoiceConfig(
                                        voiceName: settings.voiceSettings.maleVoiceName
                                    )
                                )
                            ),
                            GeminiSpeakerVoiceConfig(
                                speaker: "Female",
                                voiceConfig: GeminiVoiceConfig(
                                    prebuiltVoiceConfig: GeminiPrebuiltVoiceConfig(
                                        voiceName: settings.voiceSettings.femaleVoiceName
                                    )
                                )
                            ),
                        ]
                    )
                )
            )
        )

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(settings.geminiAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiTTSServiceError.invalidResponse(String(localized: " HTTP レスポンスを取得できませんでした。"))
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw GeminiTTSServiceError.httpError(httpResponse.statusCode, bodyText)
        }

        let decodedResponse: GeminiGenerateResponse
        do {
            decodedResponse = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        } catch {
            throw GeminiTTSServiceError.invalidResponse(String(format: String(localized: " JSON デコードに失敗しました: %@"), error.localizedDescription))
        }

        guard let inlineData = decodedResponse.candidates.first?.content.parts.compactMap(\.inlineData).first else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw GeminiTTSServiceError.invalidResponse(String(format: String(localized: " inlineData が見つかりません。応答: %@"), String(bodyText.prefix(400))))
        }

        guard let base64PCM = inlineData.data.isEmpty ? nil : inlineData.data,
              let pcmData = Data(base64Encoded: base64PCM) else {
            throw GeminiTTSServiceError.invalidResponse(String(localized: " 音声データの base64 デコードに失敗しました。"))
        }
        return makeWAVData(from: pcmData, sampleRate: 24_000, channels: 1, bitsPerSample: 16)
    }

    private func makeTTSInput(dialogues: [DialogueLine], settings: AppSettings) -> String {
        let directionBlock = makeDirectionBlock(settings: settings)
        let transcript = makeTranscript(dialogues: dialogues)

        guard !directionBlock.isEmpty else {
            return transcript
        }
        return "\(directionBlock)\n\n\(transcript)"
    }

    private func makeDirectionBlock(settings: AppSettings) -> String {
        let direction = settings.directionSettings.sceneDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !direction.isEmpty else { return "" }
        return """
        Direction:
        \(direction)
        """
    }

    private func makeTranscript(dialogues: [DialogueLine]) -> String {
        dialogues.map { dialogue in
            let speaker = dialogue.speaker == "male" ? "Male" : "Female"
            return "\(speaker): \(dialogue.text)"
        }.joined(separator: "\n")
    }

    private func makeWAVData(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(littleEndianBytes(chunkSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(littleEndianBytes(UInt32(16)))
        header.append(littleEndianBytes(UInt16(1)))
        header.append(littleEndianBytes(UInt16(channels)))
        header.append(littleEndianBytes(UInt32(sampleRate)))
        header.append(littleEndianBytes(UInt32(byteRate)))
        header.append(littleEndianBytes(UInt16(blockAlign)))
        header.append(littleEndianBytes(UInt16(bitsPerSample)))
        header.append("data".data(using: .ascii)!)
        header.append(littleEndianBytes(dataSize))

        var wavData = Data()
        wavData.append(header)
        wavData.append(pcmData)
        return wavData
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}

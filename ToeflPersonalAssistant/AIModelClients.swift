import Foundation

protocol WhisperTranscribing {
    func transcribeAudio(at audioURL: URL) async throws -> String
}

struct LocalWhisperClient: WhisperTranscribing {
    var endpoint: URL = URL(string: "http://127.0.0.1:9000/transcribe")!
    var model: String = "base"
    var language: String = "en"
    var responseFormat: String = "json"

    func transcribeAudio(at audioURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = WhisperMultipartBody(
            boundary: boundary,
            fileName: audioURL.lastPathComponent,
            mimeType: Self.mimeType(for: audioURL),
            audioData: audioData,
            model: model,
            language: language,
            responseFormat: responseFormat
        ).build()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LocalWhisper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from Whisper server"])
        }
        guard 200 ... 299 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "No server message."
            throw NSError(domain: "LocalWhisper", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Whisper server failed (\(http.statusCode)): \(body)"])
        }

        if let parsed = try? JSONDecoder().decode(WhisperTranscriptionResponse.self, from: data),
           let text = parsed.bestText,
           !text.isEmpty {
            return text
        }

        let plain = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !plain.isEmpty {
            return plain
        }

        throw NSError(domain: "LocalWhisper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Whisper response did not contain text."])
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "caf": return "audio/x-caf"
        case "m4a": return "audio/m4a"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return "audio/*"
        }
    }
}

private struct WhisperMultipartBody {
    let boundary: String
    let fileName: String
    let mimeType: String
    let audioData: Data
    let model: String
    let language: String
    let responseFormat: String

    func build() -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        func append(_ value: String) { body.append(Data(value.utf8)) }

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(audioData)
        append(lineBreak)

        appendField(name: "model", value: model, to: &body, boundary: boundary, lineBreak: lineBreak)
        appendField(name: "language", value: language, to: &body, boundary: boundary, lineBreak: lineBreak)
        appendField(name: "response_format", value: responseFormat, to: &body, boundary: boundary, lineBreak: lineBreak)

        append("--\(boundary)--\(lineBreak)")
        return body
    }

    private func appendField(name: String, value: String, to body: inout Data, boundary: String, lineBreak: String) {
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
        append("\(value)\(lineBreak)")
    }
}

private struct WhisperTranscriptionResponse: Codable {
    struct Segment: Codable {
        let text: String?
    }

    let text: String?
    let transcript: String?
    let segments: [Segment]?

    var bestText: String? {
        let direct = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        let fallback = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        let joined = segments?
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let joined, !joined.isEmpty { return joined }
        return nil
    }
}

protocol ChatCompletionProviding {
    func complete(prompt: String, temperature: Double) async throws -> String
}

struct LocalChatCompletionClient: ChatCompletionProviding {
    var endpoint: URL = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
    var model: String = "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF"

    func complete(prompt: String, temperature: Double) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionsRequest(
                model: model,
                messages: [ChatMessage(role: "user", content: prompt)],
                temperature: temperature
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LocalChatModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat completion response."])
        }
        guard 200 ... 299 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "No server message."
            throw NSError(domain: "LocalChatModel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Chat completion failed (\(http.statusCode)): \(body)"])
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "{}"
    }
}

private struct ChatCompletionsRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionsResponse: Codable {
    struct Choice: Codable {
        let message: ChatMessage
    }
    let choices: [Choice]
}

//
//  GrammarAnalyzer.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/24.
//

import Foundation

final class GrammarAnalyzer {
    static let shared = GrammarAnalyzer()
    private init() {}
    
    func analyzeTOEFLGrammar(text: String) async -> [GrammarIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [
                GrammarIssue(
                    id: UUID(),
                    message: "No speech detected",
                    snippet: ""
                )
            ]
        }

        // 🎯 NEW: TOEFL 6.0 (2026 FULL SCORE) OPTIMIZATION + ERROR CHECK
        let prompt = """
        You are a 2026 TOEFL iBT Speaking examiner (score 0–6).
        Evaluate this sentence and give:
        1. Grammar errors (tense, articles, prepositions, structure)
        2. A REWRITTEN VERSION that meets TOEFL 6.0 (full score) standard.
        Keep it short and clear.
        
        Transcript: \(trimmed)
        """

        // ✅ 1. LOCAL LM STUDIO URL (NO API KEY NEEDED)
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // ✅ 2. REMOVE API KEY HEADER (LOCAL SERVER DOESN'T NEED IT)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            // ✅ 3. USE YOUR LOCAL LLAMA 3 MODEL NAME
            "model": "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF",
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(AIResponse.self, from: data)
            let feedback = res.choices.first?.message.content ?? "No feedback"

            return [
                GrammarIssue(
                    id: UUID(),
                    message: feedback,
                    snippet: ""
                )
            ]
        } catch {
            return [
                GrammarIssue(
                    id: UUID(),
                    message: "Local AI server error\nPlease check LM Studio",
                    snippet: ""
                )
            ]
        }
    }
}

// MARK: - OpenAI Models
private struct AIResponse: Codable {
    let choices: [Choice]
}
private struct Choice: Codable {
    let message: Message
}
private struct Message: Codable {
    let content: String
}

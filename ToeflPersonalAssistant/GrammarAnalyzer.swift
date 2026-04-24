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
                GrammarIssue(id: UUID(), message: "No speech detected", snippet: "")
            ]
        }

        let prompt = """
        You are an official 2026 TOEFL iBT Speaking examiner (max score 6.0).
        
        FIRST: Provide a TOEFL 6.0 full-score revised version of the transcript.
        THEN: List all grammar errors as bullet points (*).
        
        Rules:
        - Correct all tense, article, preposition, and structure errors.
        - Use formal, academic, natural spoken English.
        - Do NOT add extra explanations.
        - Output format STRICTLY like this:
        
        ---
        TOEFL 6.0 Revised Version:
        [your revised sentence]
        
        Grammar Errors:
        * error 1
        * error 2
        * error 3
        ---
        
        Transcript: \(trimmed)
        """

        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF",
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(AIResponse.self, from: data)
            let feedback = res.choices.first?.message.content ?? "No feedback"

            // 👇 Split into separate issues
            let revisedPart = feedback.components(separatedBy: "TOEFL 6.0 Revised Version:").last?.components(separatedBy: "Grammar Errors:").first ?? ""
            let errorsPart = feedback.components(separatedBy: "Grammar Errors:").last ?? ""

            let errorLines = errorsPart.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.starts(with: "*") }

            var issues: [GrammarIssue] = []
            // Add the revised version as the first issue (no buttons in UI)
            issues.append(GrammarIssue(id: UUID(), message: "TOEFL 6.0 Revised Version:\n\(revisedPart)", snippet: ""))
            // Add each error as its own issue
            for line in errorLines {
                issues.append(GrammarIssue(id: UUID(), message: line, snippet: ""))
            }

            return issues

        } catch {
            return [
                GrammarIssue(id: UUID(), message: "Server error", snippet: "")
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

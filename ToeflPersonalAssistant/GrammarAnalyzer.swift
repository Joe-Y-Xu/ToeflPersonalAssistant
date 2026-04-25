//
//  GrammarAnalyzer.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/24.
//

import Foundation

// MARK: - STRUCTURED LLM RESPONSE (OPTIMIZED)
struct TOEFLFeedback: Codable {
    let revisedSentence: String
    let grammarErrors: [GrammarError]
}

struct GrammarError: Codable, Identifiable {
    let id: UUID
    let message: String
    let type: String
}


final class GrammarAnalyzer {
    static let shared = GrammarAnalyzer()
    private init() {}
    
    // ✅ ADD TRANSCRIBEMODE PARAM HERE
    func analyzeTOEFLGrammar(
        text: String,
        transcribeMode: TranscribeMode  // 👈 NEW PARAM
    ) async -> [GrammarIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [
                GrammarIssue(id: UUID(), message: "No speech detected", snippet: "")
            ]
        }

        // ==============================================
        // ✅ DYNAMIC PROMPT & AI TEMPERATURE (NO BREAKING CHANGES)
        // ==============================================
        let prompt: String
        let aiTemperature: Double

        switch transcribeMode {
        case .fast:
            // FAST: Quick, lightweight analysis
            prompt = """
            Quick grammar check for TOEFL speaking.
            Only list key errors with *.
            Keep it short.
            
            Transcript: \(trimmed)
            """
            aiTemperature = 0.2
            
        case .balanced:
            // BALANCED: Normal check
            prompt = """
            You are a TOEFL iBT Speaking examiner.
            Correct the transcript briefly and list grammar errors with *.
            
            Transcript: \(trimmed)
            """
            aiTemperature = 0.1
            
        case .accurate:
            // ✅ YOUR ORIGINAL FULL PROMPT (NO CHANGES)
            prompt = """
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
            aiTemperature = 0.05
        }

        // 👇 YOUR ORIGINAL NETWORK CODE — NO CHANGES
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF",
            "messages": [["role": "user", "content": prompt]],
            "temperature": aiTemperature  // ✅ DYNAMIC
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(AIResponse.self, from: data)
            let feedback = res.choices.first?.message.content ?? "No feedback"

            let components = feedback.components(separatedBy: "Grammar Errors:")
            let revisedText = components.first?.components(separatedBy: "TOEFL 6.0 Revised Version:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorsText = components.count > 1 ? components[1] : ""

            let errorLines = errorsText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.starts(with: "*") }

            var issues: [GrammarIssue] = []
            
            // ✅ Show revised version ONLY for balanced/accurate
            if transcribeMode != .fast {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: "TOEFL 6.0 Revised Version:\n\(revisedText)",
                    snippet: ""
                ))
            }

            for line in errorLines {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: line,
                    snippet: ""
                ))
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

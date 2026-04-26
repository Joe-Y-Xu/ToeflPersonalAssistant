//
//  GrammarAnalyzer.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/24.
//

import Foundation


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
        transcribeMode: TranscribeMode, // 👈 NEW PARAM
        attentionStatistics: [AttentionStatistic],
            selectedAttentionKeys: Set<String>,
            ignoredIssueItems: [IssuePreferenceItem]
    ) async -> [GrammarIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [
                GrammarIssue(id: UUID(), message: "No speech detected", snippet: "")
            ]
        }
        
        // ==============================================
        // ✅ YOUR WATCH / IGNORE WORDS (BUILT INTO PROMPT)
        // ✅ ONLY SELECTED ATTENTIONS (already correct)
        let focusWords = attentionStatistics
            .filter { selectedAttentionKeys.contains($0.id) }
            .map { $0.title }
            .joined(separator: ", ")

        // ✅ ONLY SELECTED IGNORED ITEMS (SAFE VERSION — NO ERROR)
        let avoidWords = ignoredIssueItems
            .filter { selectedAttentionKeys.contains($0.id) == false }
            .map { $0.title }
            .joined(separator: ", ")

        var focusPromptPart = ""
        if !focusWords.isEmpty {
            focusPromptPart = "\nFocus on these terms: \(focusWords)."
        }

        var avoidPromptPart = ""
        if !avoidWords.isEmpty {
            avoidPromptPart = "\nDo NOT use these terms: \(avoidWords)."
        }

        let wordRules = focusPromptPart + avoidPromptPart

        // ==============================================
        // ✅ DYNAMIC PROMPT & AI TEMPERATURE (NO BREAKING CHANGES)
        // ==============================================
        var prompt: String = ""
        let aiTemperature: Double

        var suffixPrompt = ""
        if !wordRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            
            suffixPrompt = """
            ----------------------------------------------------------------------
            IMPORTANT: The following word rules **OVERRIDE ALL OTHER RULES** if there is a conflict.
            You MUST follow these word rules strictly, no exceptions.                
            \(wordRules)
            These rules hold the highest priority
            ----------------------------------------------------------------------
            """
        }

        // Then concatenate to main prompt
        
        switch transcribeMode {
        case .fast:
            prompt = """
            You are a strict TOEFL iBT Speaking examiner (target score: 6.0/6.0).
            Your output must include BOTH:
            1) A complete high-scoring revised speech.
            2) Issue-by-issue corrections.

            OUTPUT FORMAT (strict):
            ---
            TOEFL 6.0 Revised Version:
            [full revised speech for the entire transcript]

            Grammar Errors:
            * Issue 1: [what is wrong]
              Improvement: [how to fix this part]
            * Issue 2: [what is wrong]
              Improvement: [how to fix this part]
            ---

            Rules:
            - Revise the WHOLE speech, not one sentence only.
            - Keep original meaning, but make grammar and phrasing TOEFL-appropriate.
            - Include each issue with a concrete improvement.
            Transcript: \(trimmed)
            """
            aiTemperature = 0.1
            

        case .balanced:
            prompt = """
            You are a TOEFL iBT Speaking examiner (target score: 6.0/6.0).
            Provide a complete revised speech and issue-by-issue improvements.

            OUTPUT FORMAT (strict):
            ---
            TOEFL 6.0 Revised Version:
            [full revised speech for the entire transcript]

            Grammar Errors:
            * Issue 1: [what is wrong]
              Improvement: [how to fix this part]
            * Issue 2: [what is wrong]
              Improvement: [how to fix this part]
            ---

            Rules:
            - The revised version must cover the ENTIRE speech.
            - Each bullet must include an explicit "Improvement:" line.
            - Focus on grammar, clarity, and formal TOEFL speaking style.
            Transcript: \(trimmed)
            """
            aiTemperature = 0.1
            
        case .accurate:
            prompt = """
                You are an official 2026 TOEFL iBT Speaking examiner (max score 6.0).
                
                FIRST: Provide a complete TOEFL 6.0 full-score revised version of the ENTIRE transcript.
                THEN: List all grammar errors with specific improvements.

                Rules:
                - Correct all tense, article, preposition, and structure errors.
                - Use formal, academic, natural spoken English.
                - Keep the original ideas while improving fluency and grammar.
                - For each issue, provide a concrete correction after "Improvement:".
                - Output format STRICTLY like this:
                
                ---
                TOEFL 6.0 Revised Version:
                [full revised speech for the entire transcript]
                
                Grammar Errors:
                * Issue 1: [what is wrong]
                  Improvement: [how to fix this part]
                * Issue 2: [what is wrong]
                  Improvement: [how to fix this part]
                ---
                
                Transcript: \(trimmed)
                """

            aiTemperature = 0.05
        }

        if !suffixPrompt.isEmpty {
            prompt += "\n\n\(suffixPrompt)"
        }

        
        // ⬇️ PUT THE PRINT HERE ⬇️
        print("✅ FINAL PROMPT SENT TO AI:\n\(prompt)\n──────────────────────────")
        // 👇 YOUR ORIGINAL NETWORK CODE — NO CHANGES
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF",
 //           "model": "phi-3-mini-4k-instruct",//
            "messages": [["role": "user", "content": prompt]],
            "temperature": aiTemperature  // ✅ DYNAMIC
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(AIResponse.self, from: data)
            let feedback = res.choices.first?.message.content ?? "No feedback"
            let parsed = parseFeedback(feedback)
            let revisedText = parsed.correctedTranscript
            let errorLines = parsed.grammarErrors

            var issues: [GrammarIssue] = []
            
            if !revisedText.isEmpty {
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

    private func parseFeedback(_ raw: String) -> ParsedFeedback {
        if let structured = parseJSONFeedback(from: raw) {
            return structured
        }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let revisedHeaderRegex = try? NSRegularExpression(
            pattern: #"(?i)^(?:\*{0,2}\s*)?(toefl\s*6\.0\s*revised\s*version|revised\s*version|improved\s*version|corrected\s*transcript|corrected\s*version)\s*:?\s*(?:\*{0,2})?$"#
        )
        let issuesHeaderRegex = try? NSRegularExpression(
            pattern: #"(?i)^(?:\*{0,2}\s*)?(grammar\s*errors|grammar\s*issues|detected\s*grammar\s*issues|issues)\s*:?\s*(?:\*{0,2})?$"#
        )

        var revisedHeaderLine: Int?
        var issuesHeaderLine: Int?

        for (idx, line) in lines.enumerated() {
            if revisedHeaderLine == nil, matches(regex: revisedHeaderRegex, text: line) {
                revisedHeaderLine = idx
            }
            if issuesHeaderLine == nil, matches(regex: issuesHeaderRegex, text: line) {
                issuesHeaderLine = idx
            }
        }

        var correctedTranscript = ""
        if let revisedHeaderLine {
            let start = revisedHeaderLine + 1
            let end = issuesHeaderLine ?? lines.count
            if start < end {
                correctedTranscript = lines[start..<end]
                    .joined(separator: "\n")
                    .replacingOccurrences(of: "[Improved sentence]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            correctedTranscript = lines.first(where: { line in
                !line.isEmpty && !isBulletLine(line) && !line.lowercased().contains("transcript:")
            }) ?? ""
        }

        let grammarErrors = lines.filter { isBulletLine($0) }

        return ParsedFeedback(
            correctedTranscript: correctedTranscript,
            grammarErrors: grammarErrors
        )
    }

    private func parseJSONFeedback(from raw: String) -> ParsedFeedback? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            extractCodeFenceJSON(from: trimmed)
        ].compactMap { $0 }

        for candidate in candidates {
            guard
                let data = candidate.data(using: .utf8),
                let jsonObject = try? JSONSerialization.jsonObject(with: data),
                let json = jsonObject as? [String: Any]
            else {
                continue
            }

            let corrected = (json["correctedTranscript"] as? String)
                ?? (json["revisedSentence"] as? String)
                ?? (json["revised_version"] as? String)
                ?? (json["revisedVersion"] as? String)
                ?? ""

            let errorsFromArray = (json["grammarErrors"] as? [String]) ?? []
            let errorsFromText = (json["grammarErrors"] as? String)
                .map { $0.components(separatedBy: .newlines).filter { isBulletLine($0) } } ?? []
            let mergedErrors = errorsFromArray.isEmpty ? errorsFromText : errorsFromArray

            if !corrected.isEmpty || !mergedErrors.isEmpty {
                return ParsedFeedback(
                    correctedTranscript: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
                    grammarErrors: mergedErrors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            }
        }

        return nil
    }

    private func extractCodeFenceJSON(from text: String) -> String? {
        guard text.hasPrefix("```") else { return nil }
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        return parts[1]
            .replacingOccurrences(of: "json\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(regex: NSRegularExpression?, text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func isBulletLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let first = trimmed.first, Set(["*", "•", "-"]).contains(first) {
            return true
        }
        return trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }
}

// MARK: - OpenAI Models
private struct ParsedFeedback {
    let correctedTranscript: String
    let grammarErrors: [String]
}

private struct AIResponse: Codable {
    let choices: [Choice]
}
private struct Choice: Codable {
    let message: Message
}
private struct Message: Codable {
    let content: String
}

//
//  GrammarAnalyzer.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/24.
//

import Foundation
//import AImModelClients


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
    private let chatClient: ChatCompletionProviding

    private init(chatClient: ChatCompletionProviding = LocalChatCompletionClient()) {
        self.chatClient = chatClient
    }
    
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
                GrammarIssue(id: UUID(), message: "No speech detected", snippet: "", kind: .system)
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
        let trimmedWordRules = wordRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWordRules.isEmpty {
            suffixPrompt = """
            IMPORTANT: The following word rules **HAVE HIGHEST PRIORITY** and override all other rules.
            YOU MUST FOLLOW THESE RULES:
            \(wordRules)
            """
        }

        switch transcribeMode {
        case .fast:
            prompt = """
            You are a strict TOEFL iBT Speaking examiner (target score: 6.0/6.0).
            You MUST respond **ONLY with valid JSON** — NO extra text, NO markdown, NO explanations, NO --- separators.

            \(suffixPrompt)

            Output ONLY a JSON object in THIS FORMAT:
            {
              "revised_text": "FULL TOEFL 6.0 revised speech here",
              "issues": [
                {
                  "message": "Describe the grammar/usage issue clearly",
                  "improvement": "Explain exactly how to fix it",
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Rules:
            - revised_text must be the COMPLETE corrected speech.
            - Keep original meaning.
            - Use natural, academic TOEFL English.
            - issues must be all real errors — NO separators, NO fake items.
            - isActionable = true for all real issues.
            - DO NOT include any text outside the JSON.

            Transcript: \(trimmed)
            """
            aiTemperature = 0.1

        case .balanced:
            prompt = """
            You are a TOEFL iBT Speaking examiner (target score: 6.0/6.0).
            Respond **ONLY with valid JSON** — NO extra text, NO --- separators, NO lists.

            \(suffixPrompt)

            Output ONLY JSON:
            {
              "revised_text": "FULL corrected speech",
              "issues": [
                {
                  "message": "What is wrong",
                  "improvement": "How to fix",
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Rules:
            - revised_text = complete full speech
            - Each issue must be real and actionable
            - NO non-actionable lines like dividers or notes
            - DO NOT output anything outside the JSON

            Transcript: \(trimmed)
            """
            aiTemperature = 0.1

        case .accurate:
            prompt = """
            You are an official 2026 TOEFL iBT Speaking examiner (max score 6.0).
            You MUST output **ONLY valid JSON** — NO extra text, NO separators, NO markdown, NO --- lines.

            \(suffixPrompt)

            Return ONLY JSON in this structure:
            {
              "revised_text": "Complete TOEFL 6.0 full-score speech",
              "issues": [
                {
                  "message": "Clear description of the error",
                  "improvement": "Exact correction",
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Strict Rules:
            - Correct all tense, article, preposition, structure errors.
            - Use formal academic English.
            - Keep original ideas.
            - NO non-actionable entries.
            - NO text outside JSON.

            Transcript: \(trimmed)
            """
            aiTemperature = 0.05
        }

        if !suffixPrompt.isEmpty {
            prompt += "\n\n\(suffixPrompt)"
        }

        
        // ⬇️ PUT THE PRINT HERE ⬇️
        print("✅ FINAL PROMPT SENT TO AI:\n\(prompt)\n──────────────────────────")
        do {
            let feedback = try await chatClient.complete(prompt: prompt, temperature: aiTemperature)
            let parsed = parseFeedback(feedback)
            let revisedText = parsed.correctedTranscript
            let errorLines = parsed.grammarErrors

            var issues: [GrammarIssue] = []
            
            if !revisedText.isEmpty {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: "TOEFL 6.0 Revised Version:\n\(revisedText)",
                    snippet: "",
                    kind: .revisedVersion
                ))
            }

            for line in errorLines {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: line,
                    snippet: "",
                    kind: .grammarIssue
                ))
            }

            return issues

        } catch {
            return [
                GrammarIssue(id: UUID(), message: "Server error", snippet: "", kind: .system)
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
        // 直接解析你现在的 JSON 格式：revised_text + issues
        guard let data = raw.data(using: .utf8) else { return nil }
        
        do {
            // 匹配你 AI 返回的真实结构
            struct JsonResponse: Codable {
                let revised_text: String
                let issues: [Issue]
                
                struct Issue: Codable {
                    let message: String
                    let improvement: String
                    let type: String
                    let isActionable: Bool
                }
            }
            
            // 解码 JSON
            let response = try JSONDecoder().decode(JsonResponse.self, from: data)
            
            // 把错误拼接成你 UI 能显示的文字
            let errorLines = response.issues.map { issue in
                "\(issue.message)\nImprovement: \(issue.improvement)"
            }
            
            // 返回解析好的内容 → 你的界面马上显示
            return ParsedFeedback(
                correctedTranscript: response.revised_text,
                grammarErrors: errorLines
            )
            
        } catch {
            print("🔴 JSON 解析失败: \(error.localizedDescription)")
            return nil
        }
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

private struct ParsedFeedback {
    let correctedTranscript: String
    let grammarErrors: [String]
}

//
//  GrammarAnalyzer.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/24.
//

import Foundation
//import AImModelClients


private struct ParsedFeedback {
    let correctedTranscript: String
    let grammarErrors: [String]
    let score: Int
}

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
    ) async -> (issues: [GrammarIssue], score: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (
                issues: [GrammarIssue(id: UUID(), message: "No speech detected", snippet: "", kind: .system)],
                score: 0
            )
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
            ******************************************************
            \(wordRules)
            ******************************************************
            """
        }

        switch transcribeMode {
        case .fast:
            prompt = """
            You MUST respond ONLY with valid JSON. Do NOT add any introductory text, explanations, or comments before or after the JSON. The response must start with { and end with }.
            {
              "revised_text": "Full corrected TOEFL speaking transcript, original meaning fully preserved",
              "score": 0,
              "issues": [
                {
                  "message": "Clear description of grammar / wording / style issue",
                  "improvement": "Concrete correction method",
                  "high_score_alternatives": ["phrase1","phrase2","phrase3"],
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Rules:
            - score: Numeric rating strictly 0–6, graded harshly and realistically per official 2026 TOEFL iBT Speaking rubric. Apply heavy point deductions for simple sentence structures, repetitive phrasing, weak logical connection, unclear content, awkward collocations, inconsistent tenses, limited vocabulary, and underdeveloped ideas. No inflated, lenient, or overgenerous scores.
            - revised_text: Output the full revised speech, retain all original content and logic, fix errors only.
            - Check and correct: grammar, tense, article, preposition, conjunction, word order, redundancy, unclear expression.
            - Maintain formal academic TOEFL tone; remove informal wording and non-idiomatic expressions.
            - Each issue must provide exactly 3 unique, natural, TOEFL-appropriate high-score alternative phrases.
            - Output ONLY pure JSON, no extra characters, no markdown, no line breaks outside JSON structure.

            Transcript: \(trimmed)
            """
            aiTemperature = 0.1

        case .balanced:
            prompt = """

            Output ONLY JSON:
            {
              "revised_text": "FULL corrected speech",
              "issues": [
                {
                  "message": "Describe the grammar/usage issue clearly",
                  "improvement": "Explain exactly how to fix it",
                  "high_score_alternatives": ["phrase1","phrase2","phrase3"],
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Rules:
            - Correct all tense, article, preposition, structure errors.
            - Use formal academic English.
            - For every single improvement entry, provide **3 or more distinct high-scoring TOEFL-level alternative phrases/expressions.
            - Keep original ideas.
            - DO NOT output anything outside the JSON

            Transcript: \(trimmed)
            """
            aiTemperature = 0.1

        case .accurate:
            prompt = """

            Output ONLY JSON:
            {
              "revised_text": "Complete TOEFL 6.0 full-score speech",
              "issues": [
                {
                  "message": "Describe the grammar/usage issue clearly",
                  "improvement": "Explain exactly how to fix it",
                  "high_score_alternatives": ["phrase1","phrase2","phrase3"],
                  "type": "grammar|spelling|punctuation|style|capitalization|wording",
                  "isActionable": true
                }
              ]
            }

            Strict Rules:
            - Correct all tense, article, preposition, structure errors.
            - Use formal academic English.
            - Keep original ideas.
            - For every single improvement entry, provide **3 or more distinct high-scoring TOEFL-level alternative phrases/expressions.
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
            let score = parsed.score
            
            print("🎯 LOG 1: 解析后的分数 = \(score)")
            var issues: [GrammarIssue] = []
            
            if !revisedText.isEmpty {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: "TOEFL 6.0 Revised Version:\n\(revisedText)",
                    snippet: "",
                    kind: .revisedVersion
                ))
            }
            
//            issues.append(GrammarIssue(
//                id: UUID(),
//                message: "TOEFL 2026 Speaking Score: \(score)/6",
//                snippet: "",
//                kind: .system
//            ))

            print("🎯 LOG 2: 准备添加分数到界面，分数 = \(score)")
            
            for line in errorLines {
                issues.append(GrammarIssue(
                    id: UUID(),
                    message: line,
                    snippet: "",
                    kind: .grammarIssue
                ))
            }
            print("🎯 LOG 3: 最终返回给界面的问题数量 = \(issues.count)")
            return (issues: issues, score: parsed.score)
        } catch {
            return (
                issues: [GrammarIssue(id: UUID(), message: "No speech detected", snippet: "", kind: .system)],
                score: 0
            )
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
            grammarErrors: grammarErrors,
            score: 0
        )
    }

    private func parseJSONFeedback(from raw: String) -> ParsedFeedback? {
        // 直接解析你现在的 JSON 格式：revised_text + issues
        guard let data = raw.data(using: .utf8) else { return nil }
        
        do {
            // 匹配你 AI 返回的真实结构
            struct JsonResponse: Codable {
                let revised_text: String
                let score: Int
                let issues: [Issue]
                
                struct Issue: Codable {
                    let message: String
                    let improvement: String
                    let type: String
                    let isActionable: Bool
                    let high_score_alternatives: [String]? // 👈 新增
                }
            }
            
            // 解码 JSON
            let response = try JSONDecoder().decode(JsonResponse.self, from: data)
            
            let errorLines = response.issues.map { issue in
                var text = "\(issue.message)\nImprovement: \(issue.improvement)"
                
                if let alts = issue.high_score_alternatives, !alts.isEmpty {
                    // Split any combined phrases (fixes your AI output)
                    let allPhrases = alts.flatMap {
                        $0.components(separatedBy: "; ")
                    }.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter {
                        !$0.isEmpty
                    }
                    
                    // Number ALL alternatives, no limit
                    let numbered = allPhrases.enumerated().map { index, item in
                        "\(index + 1). \(item)"
                    }.joined(separator: "\n")
                    
                    text += "\nHigh-score alternatives:\n\(numbered)"
                }
                return text
            }
            
            // 返回解析好的内容 → 你的界面马上显示
            return ParsedFeedback(
                correctedTranscript: response.revised_text,
                grammarErrors: errorLines,
                score: response.score
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



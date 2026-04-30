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

// ✅ ONLY STRUCTS NEEDED TO GET content
struct FullAIResponse: Codable {
    let choices: [Choice]
}

struct Choice: Codable {
    let message: Message
}

struct Message: Codable {
    let content: String
}

// ✅ TOEFL JSON STRUCT (unchanged)
struct TOEFLResponse: Codable {
    let revised_text: String
    let score: Int
    let issues: [Issue]
    
    struct Issue: Codable {
        let message: String
        let improvement: String
        let high_score_alternatives: [String]?
        let type: String
        let isActionable: Bool?
    }
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
                        You are an official 2026 TOEFL iBT Speaking Examiner.
                        Evaluate the transcript strictly using the official 0–6 scoring rubric across three dimensions:
                        1. Delivery: fluency, pacing, pronunciation clarity
                        2. Language Use: grammar accuracy, tense consistency, articles, prepositions, conjunctions, collocation, sentence structure variety
                        3. Topic Development: logical coherence, clear connections, no redundancy or vagueness

                        You MUST return ONLY valid JSON.
                        Do NOT add explanations, markdown, brackets, notes, or extra symbols outside the JSON.
                        Response MUST start with { and end with }.

                        JSON FORMAT:
                        {
                          "revised_text": "Fully corrected TOEFL-level transcript, preserve original meaning and ideas",
                          "score": 0,
                          "issues": [
                            {
                              "message": "Clear, specific description of the actual error",
                              "improvement": "Clear fix rule + include the EXACT original error phrase from the transcript + corrected example",
                              "high_score_alternatives": ["phrase1","phrase2","phrase3"],
                              "type": "grammar|spelling|punctuation|style|capitalization|wording|coherence",
                              "isActionable": true
                            }
                          ]
                        }

                        STRICT RULES:
                        - Score 0–6 strictly by TOEFL rubric. Grade harshly, no leniency.
                        - Heavy deductions for: simple sentences, repetition, weak logic, awkward collocations, tense errors, article/preposition mistakes, and illegal conjunctions like even though/although...but.
                        - Detect ALL errors: grammar, tense, articles, prepositions, word order, redundancy, vague phrasing, repetition, weak logic.
                        - revised_text must fix all errors, use formal academic tone, keep original content unchanged.
                        - Replace informal phrases with TOEFL-level academic expressions.
                        - All issues must be unique. No repeated messages, improvements, or alternatives.
                        - high_score_alternatives: EXACTLY 3 distinct, natural, high-level TOEFL phrases.
                        - NEVER use placeholder text such as "Concise description of the exact flaw".
                        - Output ONLY clean JSON.

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
        let cleanedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleanedRaw.data(using: .utf8) else { return nil }
        print("raw data: \(data)")
        do {
            // FIRST TRY: DIRECTLY PARSE PURE TOEFL JSON ✅
            let toefl = try JSONDecoder().decode(TOEFLResponse.self, from: data)
            
            let errorLines = toefl.issues.map { issue in
                var text = "\(issue.message)\nImprovement: \(issue.improvement)"
                
                if let alts = issue.high_score_alternatives, !alts.isEmpty {
                    let allPhrases = alts.flatMap {
                        $0.components(separatedBy: "; ")
                    }.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                    
                    let numbered = allPhrases.enumerated().map {
                        "\($0.offset + 1). \($0.element)"
                    }.joined(separator: "\n")
                    
                    text += "\nHigh-score alternatives:\n\(numbered)"
                }
                return text
            }
            
            print("✅ 1 try 最终解析结果：")
            print("📝 1 try 修正后的文本：\(toefl.revised_text)")
            print("🎯 1 try 得分：\(toefl.score)")
            print("⚠️ 1 try 错误列表：\(errorLines)")
            
            return ParsedFeedback(
                correctedTranscript: toefl.revised_text,
                grammarErrors: errorLines,
                score: toefl.score
            )
            
        } catch {
            // FALLBACK: IF IT'S WRAPPED, PARSE WRAPPER
            do {
                let aiResponse = try JSONDecoder().decode(FullAIResponse.self, from: data)
                guard let content = aiResponse.choices.first?.message.content else {
                    return nil
                }
                let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let contentData = cleanedContent.data(using: .utf8) else {
                    return nil
                }
                
                let toefl = try JSONDecoder().decode(TOEFLResponse.self, from: contentData)
                let errorLines = toefl.issues.map { issue in
                    var text = "\(issue.message)\nImprovement: \(issue.improvement)"
                    
                    if let alts = issue.high_score_alternatives, !alts.isEmpty {
                        let allPhrases = alts.flatMap {
                            $0.components(separatedBy: "; ")
                        }.map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty }
                        
                        let numbered = allPhrases.enumerated().map {
                            "\($0.offset + 1). \($0.element)"
                        }.joined(separator: "\n")
                        
                        text += "\nHigh-score alternatives:\n\(numbered)"
                    }
                    return text
                }
                
                print("✅ 2 try 最终解析结果：")
                print("📝 2 try 修正后的文本：\(toefl.revised_text)")
                print("🎯 2 try 得分：\(toefl.score)")
                print("⚠️  2 try 错误列表：\(errorLines)")

                return ParsedFeedback(
                    correctedTranscript: toefl.revised_text,
                    grammarErrors: errorLines,
                    score: toefl.score
                )
            } catch {
                print("🔴 JSON 解析失败: \(error.localizedDescription)")
                return nil
            }
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



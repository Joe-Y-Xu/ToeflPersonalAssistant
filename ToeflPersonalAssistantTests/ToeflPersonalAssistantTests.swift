//
//  ToeflPersonalAssistantTests.swift
//  ToeflPersonalAssistantTests
//
//  Created by Xu Yangzhe on 2026/4/21.
//

import Testing
@testable import ToeflPersonalAssistant

@MainActor
struct ToeflPersonalAssistantTests {

    @Test func attentionOutcomesMarkPassAndFail() async throws {
        let selected = [
            AttentionStatistic(issueKey: "repeated word detected.", title: "Repeated word detected.", passCount: 0, failCount: 0),
            AttentionStatistic(issueKey: "sentence may be missing ending punctuation.", title: "Sentence may be missing ending punctuation.", passCount: 0, failCount: 0)
        ]
        let issues = [
            GrammarIssue(message: "Repeated word detected.", snippet: "hello hello")
        ]

        let outcomes = SpeechPracticeViewModel.buildAttentionOutcomes(
            selectedStatistics: selected,
            issues: issues
        )

        #expect(outcomes.count == 2)
        #expect(outcomes.first(where: { $0.issueKey == "repeated word detected." })?.status == .failed)
        #expect(outcomes.first(where: { $0.issueKey == "sentence may be missing ending punctuation." })?.status == .passed)
    }

    @Test func attentionStatisticsAccumulateCounts() async throws {
        let statistics = [
            AttentionStatistic(issueKey: "repeated word detected.", title: "Repeated word detected.", passCount: 1, failCount: 2),
            AttentionStatistic(issueKey: "sentence may be missing ending punctuation.", title: "Sentence may be missing ending punctuation.", passCount: 0, failCount: 1)
        ]
        let outcomes = [
            AttentionOutcome(issueKey: "repeated word detected.", title: "Repeated word detected.", status: .passed, matchingIssue: nil),
            AttentionOutcome(issueKey: "sentence may be missing ending punctuation.", title: "Sentence may be missing ending punctuation.", status: .failed, matchingIssue: GrammarIssue(message: "Sentence may be missing ending punctuation.", snippet: "hello"))
        ]

        let merged = SpeechPracticeViewModel.merging(
            attentionOutcomes: outcomes,
            into: statistics
        )

        #expect(merged.first(where: { $0.issueKey == "repeated word detected." })?.passCount == 2)
        #expect(merged.first(where: { $0.issueKey == "repeated word detected." })?.failCount == 2)
        #expect(merged.first(where: { $0.issueKey == "sentence may be missing ending punctuation." })?.passCount == 0)
        #expect(merged.first(where: { $0.issueKey == "sentence may be missing ending punctuation." })?.failCount == 2)
    }
}

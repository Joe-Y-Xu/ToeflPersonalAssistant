//
//  SpeechPracticeViewModel.swift
//  ToeflPersonalAssistant
//
//  Created by Codex on 2026/4/23.
//

import AVFoundation
import Combine
import Foundation
import Speech
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct GrammarIssue: Codable, Identifiable, Hashable {
    let id: UUID
    let message: String
    let snippet: String

    var attentionKey: String {
        Self.makeAttentionKey(from: message)
    }

    init(id: UUID = UUID(), message: String, snippet: String) {
        self.id = id
        self.message = message
        self.snippet = snippet
    }

    nonisolated static func makeAttentionKey(from message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct AttentionOutcome: Codable, Identifiable, Hashable {
    enum Status: String, Codable, Hashable {
        case passed
        case failed
    }

    let issueKey: String
    let title: String
    let status: Status
    let matchingIssue: GrammarIssue?

    var id: String { issueKey }
}

struct AttentionStatistic: Codable, Identifiable, Hashable {
    let issueKey: String
    let title: String
    var passCount: Int
    var failCount: Int

    var id: String { issueKey }
}

struct SpeechRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let transcript: String
    let issues: [GrammarIssue]
    let attentionModeEnabled: Bool
    let attentionOutcomes: [AttentionOutcome]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval,
        transcript: String,
        issues: [GrammarIssue],
        attentionModeEnabled: Bool = false,
        attentionOutcomes: [AttentionOutcome] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.transcript = transcript
        self.issues = issues
        self.attentionModeEnabled = attentionModeEnabled
        self.attentionOutcomes = attentionOutcomes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case duration
        case transcript
        case issues
        case attentionModeEnabled
        case attentionOutcomes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        transcript = try container.decode(String.self, forKey: .transcript)
        issues = try container.decode([GrammarIssue].self, forKey: .issues)
        attentionModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .attentionModeEnabled) ?? false
        attentionOutcomes = try container.decodeIfPresent([AttentionOutcome].self, forKey: .attentionOutcomes) ?? []
    }
}

@MainActor
final class SpeechPracticeViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isAnalyzing = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var latestTranscript = ""
    @Published var latestIssues: [GrammarIssue] = []
    @Published var latestAttentionOutcomes: [AttentionOutcome] = []
    @Published var history: [SpeechRecord] = []
    @Published var statusText = "Tap Start Recording and speak for up to 45 seconds."
    @Published var errorText: String?
    @Published var permissionsDenied = false
    @Published var isAttentionModeEnabled = false
    @Published private(set) var selectedAttentionKeys: Set<String> = []
    @Published private(set) var attentionStatistics: [AttentionStatistic] = []

    let maxDuration: TimeInterval = 45

    var selectedAttentionStatistics: [AttentionStatistic] {
        attentionStatistics.sorted { $0.title < $1.title }
    }

    private let historyStorageKey = "speechPracticeHistory"
    private let selectedAttentionStorageKey = "speechPracticeSelectedAttentionKeys"
    private let attentionStatisticsStorageKey = "speechPracticeAttentionStatistics"
    private let attentionModeStorageKey = "speechPracticeAttentionModeEnabled"
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingStartedAt: Date?
    private var currentRecordingURL: URL?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    override init() {
        super.init()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder.dateDecodingStrategy = .iso8601
        loadHistory()
        loadAttentionSelections()
        loadAttentionStatistics()
        isAttentionModeEnabled = UserDefaults.standard.bool(forKey: attentionModeStorageKey)
    }

    func startRecording() {
        errorText = nil

        Task {
            do {
                let hasPermission = try await requestPermissions()
                guard hasPermission else {
                    statusText = "Microphone or speech recognition permission denied."
                    return
                }
                permissionsDenied = false

                try configureAudioSessionIfNeeded()
                let url = try makeRecordingURL()
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 12_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]

                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.isMeteringEnabled = true
                recorder?.record()
                recordingStartedAt = Date()
                currentRecordingURL = url

                latestAttentionOutcomes = []
                elapsedTime = 0
                isRecording = true
                statusText = isAttentionModeEnabled
                    ? "Recording with Attention Mode A enabled."
                    : "Recording..."

                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleRecordingTimerTick()
                    }
                }
            } catch {
                errorText = error.localizedDescription
                statusText = "Failed to start recording."
            }
        }
    }

    func stopRecordingAndAnalyze() {
        guard isRecording else { return }

        timer?.invalidate()
        timer = nil

        recorder?.stop()
        isRecording = false

        let duration = elapsedTime
        statusText = "Transcribing and analyzing..."
        isAnalyzing = true

        Task {
            defer { isAnalyzing = false }

            guard let fileURL = currentRecordingURL else {
                statusText = "No recording found."
                return
            }

            do {
                let transcript = try await transcribeAudioFile(at: fileURL)
                let issues = analyzeGrammar(in: transcript)
                let attentionOutcomes = isAttentionModeEnabled
                    ? Self.buildAttentionOutcomes(
                        selectedStatistics: selectedAttentionStatistics,
                        issues: issues
                    )
                    : []

                latestTranscript = transcript
                latestIssues = issues
                latestAttentionOutcomes = attentionOutcomes

                if isAttentionModeEnabled {
                    attentionStatistics = Self.merging(
                        attentionOutcomes: attentionOutcomes,
                        into: attentionStatistics
                    )
                    persistAttentionStatistics()
                }

                let record = SpeechRecord(
                    duration: duration,
                    transcript: transcript,
                    issues: issues,
                    attentionModeEnabled: isAttentionModeEnabled,
                    attentionOutcomes: attentionOutcomes
                )
                history.insert(record, at: 0)
                persistHistory()

                statusText = makeStatusText(issues: issues, attentionOutcomes: attentionOutcomes)
            } catch {
                errorText = error.localizedDescription
                statusText = "Analysis failed."
            }
        }
    }

    func setAttentionModeEnabled(_ isEnabled: Bool) {
        isAttentionModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: attentionModeStorageKey)
    }

    func toggleAttentionSelection(for issue: GrammarIssue) {
        let key = issue.attentionKey
        if selectedAttentionKeys.contains(key) {
            selectedAttentionKeys.remove(key)
            attentionStatistics.removeAll { $0.issueKey == key }
        } else {
            selectedAttentionKeys.insert(key)
            if attentionStatistics.contains(where: { $0.issueKey == key }) == false {
                attentionStatistics.append(
                    AttentionStatistic(
                        issueKey: key,
                        title: issue.message,
                        passCount: 0,
                        failCount: 0
                    )
                )
            }
        }

        persistAttentionSelections()
        persistAttentionStatistics()
    }

    func removeAttention(issueKey: String) {
        selectedAttentionKeys.remove(issueKey)
        attentionStatistics.removeAll { $0.issueKey == issueKey }
        persistAttentionSelections()
        persistAttentionStatistics()
    }

    func clearAllAttentions() {
        selectedAttentionKeys.removeAll()
        attentionStatistics.removeAll()
        persistAttentionSelections()
        persistAttentionStatistics()
    }

    func isAttentionSelected(_ issue: GrammarIssue) -> Bool {
        selectedAttentionKeys.contains(issue.attentionKey)
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func deleteRecord(id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    func openPrivacySettings() {
#if os(macOS)
        let microphoneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        let speechURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")

        if let microphoneURL {
            NSWorkspace.shared.open(microphoneURL)
        } else if let speechURL {
            NSWorkspace.shared.open(speechURL)
        } else if let privacyURL {
            NSWorkspace.shared.open(privacyURL)
        }
#elseif os(iOS)
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
#endif
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyStorageKey) else { return }
        guard let decoded = try? jsonDecoder.decode([SpeechRecord].self, from: data) else { return }
        history = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistHistory() {
        guard let data = try? jsonEncoder.encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyStorageKey)
    }

    private func loadAttentionSelections() {
        guard let data = UserDefaults.standard.data(forKey: selectedAttentionStorageKey) else { return }
        guard let decoded = try? jsonDecoder.decode([String].self, from: data) else { return }
        selectedAttentionKeys = Set(decoded)
    }

    private func persistAttentionSelections() {
        guard let data = try? jsonEncoder.encode(Array(selectedAttentionKeys).sorted()) else { return }
        UserDefaults.standard.set(data, forKey: selectedAttentionStorageKey)
    }

    private func loadAttentionStatistics() {
        guard let data = UserDefaults.standard.data(forKey: attentionStatisticsStorageKey) else { return }
        guard let decoded = try? jsonDecoder.decode([AttentionStatistic].self, from: data) else { return }
        attentionStatistics = decoded.filter { selectedAttentionKeys.contains($0.issueKey) }
    }

    private func persistAttentionStatistics() {
        let filtered = attentionStatistics.filter { selectedAttentionKeys.contains($0.issueKey) }
        guard let data = try? jsonEncoder.encode(filtered) else { return }
        UserDefaults.standard.set(data, forKey: attentionStatisticsStorageKey)
    }

    private func makeStatusText(issues: [GrammarIssue], attentionOutcomes: [AttentionOutcome]) -> String {
        if isAttentionModeEnabled {
            guard selectedAttentionKeys.isEmpty == false else {
                return "Attention Mode A is on, but no attentions are selected yet."
            }

            let failedCount = attentionOutcomes.filter { $0.status == .failed }.count
            let passedCount = attentionOutcomes.filter { $0.status == .passed }.count
            return "Attention review: \(failedCount) fail(s), \(passedCount) pass(es)."
        }

        return issues.isEmpty
            ? "No obvious grammar issues found."
            : "Found \(issues.count) possible grammar issue(s)."
    }

    private func makeRecordingURL() throws -> URL {
        let folder = try recordingsFolderURL()
        let name = "recording-\(UUID().uuidString).m4a"
        return folder.appendingPathComponent(name, conformingTo: .audio)
    }

    private func recordingsFolderURL() throws -> URL {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsURL = docsURL.appendingPathComponent("SpeechRecordings", isDirectory: true)

        if !FileManager.default.fileExists(atPath: recordingsURL.path) {
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        }

        return recordingsURL
    }

    private func requestPermissions() async throws -> Bool {
        let speechStatus = await currentSpeechAuthorizationStatus()
        let speechAuthorized = speechStatus == .authorized

#if os(iOS) || os(tvOS) || os(visionOS)
        let micAuthorized = await currentIOSMicAuthorizationStatus()
#elseif os(macOS)
        let micAuthorized = await currentMacMicAuthorizationStatus()
#else
        let micAuthorized = true
#endif

        if !speechAuthorized || !micAuthorized {
            permissionsDenied = true
            statusText = permissionStatusMessage(speechAuthorized: speechAuthorized, micAuthorized: micAuthorized)
        } else {
            permissionsDenied = false
        }

        return speechAuthorized && micAuthorized
    }

    private func currentSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus != .notDetermined {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

#if os(iOS) || os(tvOS) || os(visionOS)
    private func currentIOSMicAuthorizationStatus() async -> Bool {
        if AVAudioSession.sharedInstance().recordPermission == .granted {
            return true
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
#endif

#if os(macOS)
    private func currentMacMicAuthorizationStatus() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
#endif

    private func permissionStatusMessage(speechAuthorized: Bool, micAuthorized: Bool) -> String {
        if !speechAuthorized && !micAuthorized {
            return "Speech recognition and microphone permissions are denied. Enable both in System Settings > Privacy & Security."
        }
        if !speechAuthorized {
            return "Speech recognition permission is denied. Enable it in System Settings > Privacy & Security > Speech Recognition."
        }
        if !micAuthorized {
            return "Microphone permission is denied. Enable it in System Settings > Privacy & Security > Microphone."
        }
        return "Permissions unavailable."
    }

    private func configureAudioSessionIfNeeded() throws {
#if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true)
#endif
    }

    private func transcribeAudioFile(at url: URL) async throws -> String {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(
                domain: "SpeechPractice",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available right now."]
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            speechRecognizer.recognitionTask(with: request) { result, error in
                if let error, didResume == false {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal, didResume == false else { return }
                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    private func analyzeGrammar(in text: String) -> [GrammarIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [GrammarIssue(message: "No speech was detected.", snippet: "")]
        }

        var issues: [GrammarIssue] = []
        let sentences = splitIntoSentences(trimmed)

        for sentence in sentences {
            let normalized = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { continue }

            if let first = normalized.first, first.isLetter, first.isLowercase {
                issues.append(
                    GrammarIssue(
                        message: "Sentence should start with a capital letter.",
                        snippet: normalized
                    )
                )
            }

            if let last = normalized.last, ![".", "!", "?"].contains(last) {
                issues.append(
                    GrammarIssue(
                        message: "Sentence may be missing ending punctuation.",
                        snippet: normalized
                    )
                )
            }

            let words = normalized.split(separator: " ").map(String.init)
            if words.count < 3 {
                issues.append(
                    GrammarIssue(
                        message: "Sentence may be too short or a fragment.",
                        snippet: normalized
                    )
                )
            }
        }

        let lowerText = trimmed.lowercased()
        let agreementPairs: [(String, String)] = [
            ("i is", "Use \"I am\" instead of \"I is\"."),
            ("he are", "Use \"he is\" instead of \"he are\"."),
            ("she are", "Use \"she is\" instead of \"she are\"."),
            ("they is", "Use \"they are\" instead of \"they is\"."),
            ("we was", "Use \"we were\" instead of \"we was\"."),
            ("i were", "Use \"I was\" instead of \"I were\".")
        ]
        for (pattern, message) in agreementPairs where lowerText.contains(pattern) {
            issues.append(GrammarIssue(message: message, snippet: pattern))
        }

        let repeatedWordPattern = #"\b([A-Za-z]+)\s+\1\b"#
        if let regex = try? NSRegularExpression(pattern: repeatedWordPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            regex.matches(in: trimmed, options: [], range: nsRange).forEach { match in
                if let range = Range(match.range, in: trimmed) {
                    let snippet = String(trimmed[range])
                    issues.append(GrammarIssue(message: "Repeated word detected.", snippet: snippet))
                }
            }
        }

        return Array(Set(issues)).sorted { $0.message < $1.message }
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: ". ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map(String.init)
    }

    private func handleRecordingTimerTick() {
        guard let startedAt = recordingStartedAt else { return }

        let duration = Date().timeIntervalSince(startedAt)
        elapsedTime = min(duration, maxDuration)

        if duration >= maxDuration {
            stopRecordingAndAnalyze()
        }
    }

    nonisolated static func buildAttentionOutcomes(
        selectedStatistics: [AttentionStatistic],
        issues: [GrammarIssue]
    ) -> [AttentionOutcome] {
        selectedStatistics
            .sorted { $0.title < $1.title }
            .map { statistic in
                let matchingIssue = issues.first {
                    GrammarIssue.makeAttentionKey(from: $0.message) == statistic.issueKey
                }
                return AttentionOutcome(
                    issueKey: statistic.issueKey,
                    title: statistic.title,
                    status: matchingIssue != nil ? .failed : .passed,
                    matchingIssue: matchingIssue
                )
            }
    }

    nonisolated static func merging(
        attentionOutcomes: [AttentionOutcome],
        into statistics: [AttentionStatistic]
    ) -> [AttentionStatistic] {
        var updated = Dictionary(uniqueKeysWithValues: statistics.map { ($0.issueKey, $0) })

        for outcome in attentionOutcomes {
            guard var statistic = updated[outcome.issueKey] else { continue }
            switch outcome.status {
            case .passed:
                statistic.passCount += 1
            case .failed:
                statistic.failCount += 1
            }
            updated[outcome.issueKey] = statistic
        }

        return Array(updated.values).sorted { $0.title < $1.title }
    }
}

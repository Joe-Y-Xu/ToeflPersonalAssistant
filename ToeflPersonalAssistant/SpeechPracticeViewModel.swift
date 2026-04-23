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

struct IssuePreferenceItem: Codable, Identifiable, Hashable {
    let issueKey: String
    let title: String

    var id: String { issueKey }
}

struct SpeechRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let recordingFileName: String?
    let transcript: String
    let issues: [GrammarIssue]
    let attentionModeEnabled: Bool
    let attentionOutcomes: [AttentionOutcome]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval,
        recordingFileName: String? = nil,
        transcript: String,
        issues: [GrammarIssue],
        attentionModeEnabled: Bool = false,
        attentionOutcomes: [AttentionOutcome] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.recordingFileName = recordingFileName
        self.transcript = transcript
        self.issues = issues
        self.attentionModeEnabled = attentionModeEnabled
        self.attentionOutcomes = attentionOutcomes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case duration
        case recordingFileName
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
        recordingFileName = try container.decodeIfPresent(String.self, forKey: .recordingFileName)
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
    @Published private(set) var currentlyPlayingRecordID: UUID?
    @Published private(set) var isPlayingLatestRecording = false
    @Published private(set) var selectedAttentionKeys: Set<String> = []
    @Published private(set) var attentionStatistics: [AttentionStatistic] = []
    @Published private(set) var ignoredIssueKeys: Set<String> = []
    @Published private(set) var ignoredIssueItems: [IssuePreferenceItem] = []

    let maxDuration: TimeInterval = 45

    var selectedAttentionStatistics: [AttentionStatistic] {
        attentionStatistics.sorted { $0.title < $1.title }
    }

    var selectedIgnoredIssues: [IssuePreferenceItem] {
        ignoredIssueItems.sorted { $0.title < $1.title }
    }

    private let historyStorageKey = "speechPracticeHistory"
    private let selectedAttentionStorageKey = "speechPracticeSelectedAttentionKeys"
    private let attentionStatisticsStorageKey = "speechPracticeAttentionStatistics"
    private let attentionModeStorageKey = "speechPracticeAttentionModeEnabled"
    private let ignoredIssuesStorageKey = "speechPracticeIgnoredIssues"
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingStartedAt: Date?
    private var currentRecordingURL: URL?
    private var recordingStopContinuation: CheckedContinuation<Void, Error>?
    private var audioPlayer: AVAudioPlayer?
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
        loadIgnoredIssues()
        sanitizePreferences()
        isAttentionModeEnabled = UserDefaults.standard.bool(forKey: attentionModeStorageKey)
    }

    func startRecording() {
        errorText = nil
        stopPlayback()

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
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false
                ]

                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.delegate = self
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

        let activeRecorder = recorder
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
                try await stopRecorderAndWaitUntilFinished(activeRecorder)
                let transcript = try await transcribeAudioFile(at: fileURL)
                let issues = analyzeGrammar(in: transcript)
                let filteredIssues = issues.filter { ignoredIssueKeys.contains($0.attentionKey) == false }
                let attentionOutcomes = isAttentionModeEnabled
                    ? Self.buildAttentionOutcomes(
                        selectedStatistics: selectedAttentionStatistics,
                        issues: filteredIssues
                    )
                    : []

                latestTranscript = transcript
                latestIssues = filteredIssues
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
                    recordingFileName: fileURL.lastPathComponent,
                    transcript: transcript,
                    issues: filteredIssues,
                    attentionModeEnabled: isAttentionModeEnabled,
                    attentionOutcomes: attentionOutcomes
                )
                history.insert(record, at: 0)
                persistHistory()

                statusText = makeStatusText(issues: filteredIssues, attentionOutcomes: attentionOutcomes)
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
        setAttentionSelection(isEnabled: !isAttentionSelected(issue), issueKey: issue.attentionKey, title: issue.message)
    }

    func removeAttention(issueKey: String) {
        setAttentionSelection(isEnabled: false, issueKey: issueKey, title: nil)
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

    func isAttentionSelected(issueKey: String) -> Bool {
        selectedAttentionKeys.contains(issueKey)
    }

    func setAttentionSelection(isEnabled: Bool, issueKey: String, title: String?) {
        if isEnabled {
            ignoredIssueKeys.remove(issueKey)
            ignoredIssueItems.removeAll { $0.issueKey == issueKey }
            selectedAttentionKeys.insert(issueKey)
            if attentionStatistics.contains(where: { $0.issueKey == issueKey }) == false {
                attentionStatistics.append(
                    AttentionStatistic(
                        issueKey: issueKey,
                        title: title ?? issueKey,
                        passCount: 0,
                        failCount: 0
                    )
                )
            }
        } else {
            selectedAttentionKeys.remove(issueKey)
            attentionStatistics.removeAll { $0.issueKey == issueKey }
        }

        persistAttentionSelections()
        persistAttentionStatistics()
        persistIgnoredIssues()
    }

    func toggleIgnoreSelection(for issue: GrammarIssue) {
        setIgnoreSelection(isEnabled: !isIgnored(issue), issueKey: issue.attentionKey, title: issue.message)
    }

    func setIgnoreSelection(isEnabled: Bool, issueKey: String, title: String?) {
        if isEnabled {
            guard selectedAttentionKeys.contains(issueKey) == false else { return }
            ignoredIssueKeys.insert(issueKey)
            if ignoredIssueItems.contains(where: { $0.issueKey == issueKey }) == false {
                ignoredIssueItems.append(IssuePreferenceItem(issueKey: issueKey, title: title ?? issueKey))
            }
        } else {
            ignoredIssueKeys.remove(issueKey)
            ignoredIssueItems.removeAll { $0.issueKey == issueKey }
        }

        persistIgnoredIssues()
    }

    func isIgnored(_ issue: GrammarIssue) -> Bool {
        ignoredIssueKeys.contains(issue.attentionKey)
    }

    func isIgnored(issueKey: String) -> Bool {
        ignoredIssueKeys.contains(issueKey)
    }

    func clearAllIgnoredIssues() {
        ignoredIssueKeys.removeAll()
        ignoredIssueItems.removeAll()
        persistIgnoredIssues()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func deleteRecord(id: UUID) {
        if currentlyPlayingRecordID == id {
            stopPlayback()
        }
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func clearHistory() {
        stopPlayback()
        history.removeAll()
        persistHistory()
    }

    func toggleLatestRecordingPlayback() {
        guard let currentRecordingURL else { return }

        if isPlayingLatestRecording {
            stopPlayback()
            return
        }

        playAudio(at: currentRecordingURL, recordID: nil)
    }

    func togglePlayback(for record: SpeechRecord) {
        guard let recordingURL = recordingURL(for: record) else { return }

        if currentlyPlayingRecordID == record.id {
            stopPlayback()
            return
        }

        playAudio(at: recordingURL, recordID: record.id)
    }

    func isPlaybackAvailable(for record: SpeechRecord) -> Bool {
        recordingURL(for: record) != nil
    }

    func isPlaying(record: SpeechRecord) -> Bool {
        currentlyPlayingRecordID == record.id
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentlyPlayingRecordID = nil
        isPlayingLatestRecording = false
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

    private func loadIgnoredIssues() {
        guard let data = UserDefaults.standard.data(forKey: ignoredIssuesStorageKey) else { return }
        guard let decoded = try? jsonDecoder.decode([IssuePreferenceItem].self, from: data) else { return }
        ignoredIssueItems = decoded
        ignoredIssueKeys = Set(decoded.map(\.issueKey))
    }

    private func persistIgnoredIssues() {
        let filtered = ignoredIssueItems.filter { ignoredIssueKeys.contains($0.issueKey) }
        guard let data = try? jsonEncoder.encode(filtered.sorted { $0.title < $1.title }) else { return }
        UserDefaults.standard.set(data, forKey: ignoredIssuesStorageKey)
    }

    private func sanitizePreferences() {
        ignoredIssueKeys.subtract(selectedAttentionKeys)
        ignoredIssueItems.removeAll { selectedAttentionKeys.contains($0.issueKey) }
        attentionStatistics = attentionStatistics.filter { selectedAttentionKeys.contains($0.issueKey) }
        ignoredIssueItems = ignoredIssueItems.filter { ignoredIssueKeys.contains($0.issueKey) }
        persistAttentionSelections()
        persistAttentionStatistics()
        persistIgnoredIssues()
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
        let name = "recording-\(UUID().uuidString).caf"
        return folder.appendingPathComponent(name, conformingTo: .audio)
    }

    private func recordingURL(for record: SpeechRecord) -> URL? {
        guard let recordingFileName = record.recordingFileName else { return nil }
        guard let folder = try? recordingsFolderURL() else { return nil }

        let fileURL = folder.appendingPathComponent(recordingFileName)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func playAudio(at url: URL, recordID: UUID?) {
        do {
            stopPlayback()
            try configurePlaybackSessionIfNeeded()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            currentlyPlayingRecordID = recordID
            isPlayingLatestRecording = recordID == nil
        } catch {
            errorText = error.localizedDescription
            statusText = "Unable to play this recording."
            stopPlayback()
        }
    }

    private func stopRecorderAndWaitUntilFinished(_ activeRecorder: AVAudioRecorder?) async throws {
        guard let activeRecorder else { return }

        if activeRecorder.isRecording == false {
            recorder = nil
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recordingStopContinuation = continuation
            activeRecorder.stop()
        }
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

    private func configurePlaybackSessionIfNeeded() throws {
#if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
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

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var didResume = false

            speechRecognizer.recognitionTask(with: request) { result, error in
                if let error, didResume == false {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal, didResume == false else { return }
                didResume = true
                continuation.resume(returning: result)
            }
        }

        return formattedTranscript(from: result)
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

    private func formattedTranscript(from result: SFSpeechRecognitionResult) -> String {
        let rawTranscript = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let segments = result.bestTranscription.segments
        guard segments.count > 1 else {
            return rawTranscript
        }

        let containsSentenceEndingPunctuation = rawTranscript.contains { ".!?".contains($0) }
        if containsSentenceEndingPunctuation {
            return rawTranscript
        }

        var sentences: [String] = []
        var currentSentenceParts: [String] = []
        var previousSegmentEndTime: TimeInterval?

        for segment in segments {
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }

            let currentSegmentStartTime = segment.timestamp
            let shouldStartNewSentence: Bool
            if let previousSegmentEndTime {
                shouldStartNewSentence = currentSegmentStartTime - previousSegmentEndTime > 1.1
            } else {
                shouldStartNewSentence = false
            }

            if shouldStartNewSentence, currentSentenceParts.isEmpty == false {
                sentences.append(makeSentence(from: currentSentenceParts))
                currentSentenceParts.removeAll()
            }

            currentSentenceParts.append(text)
            previousSegmentEndTime = segment.timestamp + segment.duration
        }

        if currentSentenceParts.isEmpty == false {
            sentences.append(makeSentence(from: currentSentenceParts))
        }

        let reconstructedTranscript = sentences
            .filter { $0.isEmpty == false }
            .joined(separator: " ")

        return reconstructedTranscript.isEmpty ? rawTranscript : reconstructedTranscript
    }

    private func makeSentence(from parts: [String]) -> String {
        let sentence = parts
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard sentence.isEmpty == false else { return "" }

        let capitalizedSentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        if let lastCharacter = capitalizedSentence.last, ".!?".contains(lastCharacter) {
            return capitalizedSentence
        }

        return capitalizedSentence + "."
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

extension SpeechPracticeViewModel: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recorder = nil

            guard let continuation = self.recordingStopContinuation else { return }
            self.recordingStopContinuation = nil

            if flag {
                continuation.resume()
            } else {
                continuation.resume(
                    throwing: NSError(
                        domain: "SpeechPractice",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Recording stopped before the audio file finished saving."]
                    )
                )
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recorder = nil

            guard let continuation = self.recordingStopContinuation else { return }
            self.recordingStopContinuation = nil
            continuation.resume(
                throwing: error ?? NSError(
                    domain: "SpeechPractice",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The recorder failed while saving audio."]
                )
            )
        }
    }
}
extension SpeechPracticeViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stopPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorText = error?.localizedDescription ?? "Unable to decode this recording."
            self.stopPlayback()
        }
    }
}


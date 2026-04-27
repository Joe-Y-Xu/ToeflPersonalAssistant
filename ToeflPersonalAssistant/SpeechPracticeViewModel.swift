//
//  SpeechPracticeViewModel.swift
//  ToeflPersonalAssistant
//
//  Created by Codex on 2026/4/23.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import NaturalLanguage
#endif

struct GrammarIssue: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case revisedVersion
        case grammarIssue
        case system
    }

    let id: UUID
    let message: String
    let snippet: String
    let kind: Kind

    var attentionKey: String {
        Self.makeAttentionKey(from: message)
    }

    var isActionable: Bool {
        kind == .grammarIssue
    }

    init(id: UUID = UUID(), message: String, snippet: String, kind: Kind = .grammarIssue) {
        self.id = id
        self.message = message
        self.snippet = snippet
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case message
        case snippet
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        message = try container.decode(String.self, forKey: .message)
        snippet = try container.decode(String.self, forKey: .snippet)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .grammarIssue
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
    var issueKey: String
    var title: String
    var passCount: Int
    var failCount: Int

    var id: String { issueKey }
}

struct IssuePreferenceItem: Codable, Identifiable, Hashable {
    var issueKey: String
    var title: String

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
    @Published var transcribeMode: TranscribeMode = .fast
    
    let maxDuration: TimeInterval = 45

    var selectedAttentionStatistics: [AttentionStatistic] {
        attentionStatistics.sorted { $0.title < $1.title }
    }

    var selectedIgnoredIssues: [IssuePreferenceItem] {
        ignoredIssueItems.sorted { $0.title < $1.title }
    }
    
    func removeIgnoredIssue(issueKey: String) {
        ignoredIssueKeys.remove(issueKey)
        ignoredIssueItems.removeAll { $0.issueKey == issueKey }
        persistIgnoredIssues()
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
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let whisperClient: WhisperTranscribing = LocalWhisperClient()

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
    
    // MARK: - Edit Attention / Ignore Item
    func updateAttentionOrIgnoreItem(oldKey: String, newTitle: String) {
        let newKey = newTitle
        
        // Update Attention
        if let index = attentionStatistics.firstIndex(where: { $0.issueKey == oldKey }) {
            attentionStatistics[index].title = newTitle
            attentionStatistics[index].issueKey = newKey
        }
        
        // Update Ignored
        if let index = ignoredIssueItems.firstIndex(where: { $0.issueKey == oldKey }) {
            ignoredIssueItems[index].title = newTitle
            ignoredIssueItems[index].issueKey = newKey
        }
        
        // Update key sets
        if selectedAttentionKeys.contains(oldKey) {
            selectedAttentionKeys.remove(oldKey)
            selectedAttentionKeys.insert(newKey)
        }
        
        if ignoredIssueKeys.contains(oldKey) {
            ignoredIssueKeys.remove(oldKey)
            ignoredIssueKeys.insert(newKey)
        }
        
        persistAttentionSelections()
        persistAttentionStatistics()
        persistIgnoredIssues()
    }
    
    // ADD Removing ignoredIssues
    func deleteFromIgnored(issueKey: String) {
        ignoredIssueKeys.remove(issueKey)
    }
    // ✅ FOR YOUR VARIABLES: selectedAttentionKeys + ignoredIssueItems
    func generateTranscriptionPrompt() -> String {
        // Base clear prompt for Whisper
        var prompt = "Transcribe the audio clearly and accurately in American English."
        
        // 🔹 Add WORDS TO FOCUS (Watch List)
        let focusTitles = attentionStatistics
            .filter { selectedAttentionKeys.contains($0.id) }
            .map { $0.title }
        
        if !focusTitles.isEmpty {
            let focusString = focusTitles.joined(separator: ", ")
            prompt += " Focus on these key terms: \(focusString)."
        }
        
        // 🔹 Add WORDS TO AVOID (Ignore List)
        let ignoreTitles = ignoredIssueItems
            .map { $0.title }
        
        if !ignoreTitles.isEmpty {
            let ignoreString = ignoreTitles.joined(separator: ", ")
            prompt += " Do NOT transcribe these words: \(ignoreString)."
        }
        
        return prompt
    }

    func startRecording() {
        errorText = nil
        stopPlayback()

        Task {
            do {
                let hasPermission = try await requestPermissions()
                guard hasPermission else {
                    statusText = "Microphone permission denied."
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
                await MainActor.run {
                    statusText = "No recording found."
                }
                return
            }

            do {
                try await stopRecorderAndWaitUntilFinished(activeRecorder)
                let transcript = try await transcribeAudioFile(at: fileURL)
                
                // ✅ 1. Run AI TOEFL Grammar Check (async + await)
                let issues = await analyzeGrammar(in: transcript)
                
                // ✅ 2. Filter ignored issues
                let filteredIssues = issues.filter {
                    !ignoredIssueKeys.contains($0.attentionKey)
                }
                
                // ✅ 3. Attention mode logic
                let attentionOutcomes = isAttentionModeEnabled
                    ? Self.buildAttentionOutcomes(
                        selectedStatistics: selectedAttentionStatistics,
                        issues: filteredIssues
                    )
                    : []

                // ✅ 4. Update UI on Main Thread
                await MainActor.run {
                    self.latestTranscript = transcript
                    self.latestIssues = filteredIssues
                    self.latestAttentionOutcomes = attentionOutcomes
                }

                // ✅ 5. Update attention stats
                if isAttentionModeEnabled {
                    await MainActor.run {
                        self.attentionStatistics = Self.merging(
                            attentionOutcomes: attentionOutcomes,
                            into: self.attentionStatistics
                        )
                        self.persistAttentionStatistics()
                    }
                }

                // ✅ 6. Save record
                let record = SpeechRecord(
                    duration: duration,
                    recordingFileName: fileURL.lastPathComponent,
                    transcript: transcript,
                    issues: filteredIssues,
                    attentionModeEnabled: isAttentionModeEnabled,
                    attentionOutcomes: attentionOutcomes
                )
                
                await MainActor.run {
                    self.history.insert(record, at: 0)
                    self.persistHistory()
                    self.statusText = self.makeStatusText(issues: filteredIssues, attentionOutcomes: attentionOutcomes)
                }

            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.statusText = "Analysis failed."
                }
            }
        }
    }

    func setAttentionModeEnabled(_ isEnabled: Bool) {
        isAttentionModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: attentionModeStorageKey)
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

    func toggleAttentionSelection(for issue: GrammarIssue) {
        let cleanTitle = issue.message.components(separatedBy: .newlines).first ?? issue.message
            setAttentionSelection(isEnabled: !isAttentionSelected(issue), issueKey: issue.attentionKey, title: cleanTitle)
    }

    
    func toggleIgnoreSelection(for issue: GrammarIssue) {
        let cleanTitle = issue.message.components(separatedBy: .newlines).first ?? issue.message
            setIgnoreSelection(isEnabled: !isIgnored(issue), issueKey: issue.attentionKey, title: cleanTitle)
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
    
    // 加到 class SpeechPracticeViewModel 里面
    @Published var showClearHistoryAlert = false

    func clearHistory() {
        showClearHistoryAlert = true
    }

    // 这个函数名必须完全一样！
    func confirmClearHistory() {
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
                return "Attention Model is on, but no attentions are selected yet."
            }

            let failedCount = attentionOutcomes.filter { $0.status == .failed }.count
            let passedCount = attentionOutcomes.filter { $0.status == .passed }.count
            return "Attention review: \(failedCount) fail(s), \(passedCount) pass(es)."
        }

        let grammarOnly = issues.filter { $0.kind == .grammarIssue }
        return grammarOnly.isEmpty
            ? "No obvious grammar issues found."
            : "Found \(grammarOnly.count) possible grammar issue(s)."
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
#if os(iOS) || os(tvOS) || os(visionOS)
        let micAuthorized = await currentIOSMicAuthorizationStatus()
#elseif os(macOS)
        let micAuthorized = await currentMacMicAuthorizationStatus()
#else
        let micAuthorized = true
#endif

        if !micAuthorized {
            permissionsDenied = true
            statusText = permissionStatusMessage(micAuthorized: micAuthorized)
        } else {
            permissionsDenied = false
        }

        return micAuthorized
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

    private func permissionStatusMessage(micAuthorized: Bool) -> String {
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
        let transcribedText = try await whisperClient.transcribeAudio(at: url)
        let cleanedText = transcribedText.replacingOccurrences(of: "  ", with: " ")
        return cleanedText.isEmpty ? "(No transcription available)" : cleanedText
    }
    
    


    // ✅ APPLE AI GRAMMAR ANALYSIS (TOEFL-LEVEL ACCURACY)
//    private func analyzeGrammar(in text: String) -> [GrammarIssue] {
//        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
//        guard !trimmed.isEmpty else {
//            return [GrammarIssue(id: UUID(), message: "No speech detected.", snippet: "")]
//        }
//        
//        var issues = [GrammarIssue]()
//        
//        // ✅ APPLE OFFICIAL BUILT-IN GRAMMAR ENGINE (ONLY THIS)
//        let checker = NSSpellChecker.shared
//        let fullRange = NSRange(text.startIndex..., in: text)
//        
//        // Real grammar detection (no primitive code)
//        let results = checker.check(
//            trimmed,
//            range: fullRange,
//            types: NSTextCheckingResult.CheckingType.grammar.rawValue,
//            options: [:],
//            inSpellDocumentWithTag: 0,
//            orthography: nil,
//            wordCount: nil
//        )
//        
//        // Convert Apple's results to your GrammarIssue
//        for result in results {
//            guard let range = Range(result.range, in: trimmed) else { continue }
//            let snippet = String(trimmed[range])
//            
//            issues.append(GrammarIssue(
//                id: UUID(),
//                message: "Grammar Issue (TOEFL Relevant)",
//                snippet: snippet
//            ))
//        }
//        
//        // Final result
//        if issues.isEmpty {
//            return [GrammarIssue(
//                id: UUID(),
//                message: "No grammar issues detected. Good TOEFL structure!",
//                snippet: ""
//            )]
//        }
//        
//        return Array(Set(issues))
//    }
//    
// Large language model
    // ✅ REPLACES OLD FUNCTION — CLEAN & SIMPLE
    private func analyzeGrammar(in text: String) async -> [GrammarIssue] {
        await GrammarAnalyzer.shared.analyzeTOEFLGrammar(
                text: text, 
                transcribeMode: transcribeMode,
                attentionStatistics: attentionStatistics,
                selectedAttentionKeys: selectedAttentionKeys,
                ignoredIssueItems: ignoredIssueItems
        )
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


struct AIResponse: Codable {
    let revised_text: String
    let issues: [GrammarIssue]
}

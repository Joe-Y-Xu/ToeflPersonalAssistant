//
//  SpeechPracticeViewModel.swift
//  ToeflPersonalAssistant
//
//  Created by Codex on 2026/4/23.
//

import Foundation
import AVFoundation
import Speech
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct GrammarIssue: Codable, Identifiable, Hashable {
    let id: UUID
    let message: String
    let snippet: String

    init(id: UUID = UUID(), message: String, snippet: String) {
        self.id = id
        self.message = message
        self.snippet = snippet
    }
}

struct SpeechRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let transcript: String
    let issues: [GrammarIssue]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval,
        transcript: String,
        issues: [GrammarIssue]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.transcript = transcript
        self.issues = issues
    }
}

@MainActor
final class SpeechPracticeViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isAnalyzing = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var latestTranscript = ""
    @Published var latestIssues: [GrammarIssue] = []
    @Published var history: [SpeechRecord] = []
    @Published var statusText = "Tap Start Recording and speak for up to 45 seconds."
    @Published var errorText: String?

    let maxDuration: TimeInterval = 45

    private let historyStorageKey = "speechPracticeHistory"
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

                elapsedTime = 0
                isRecording = true
                statusText = "Recording..."

                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard let startedAt = self.recordingStartedAt else { return }

                    let duration = Date().timeIntervalSince(startedAt)
                    self.elapsedTime = min(duration, self.maxDuration)

                    if duration >= self.maxDuration {
                        self.stopRecordingAndAnalyze()
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

                latestTranscript = transcript
                latestIssues = issues

                let record = SpeechRecord(duration: duration, transcript: transcript, issues: issues)
                history.insert(record, at: 0)
                persistHistory()

                statusText = issues.isEmpty ? "No obvious grammar issues found." : "Found \(issues.count) possible grammar issue(s)."
            } catch {
                errorText = error.localizedDescription
                statusText = "Analysis failed."
            }
        }
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
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
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

#if os(iOS) || os(tvOS) || os(visionOS)
        let micAuthorized = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
#elseif os(macOS)
        let micAuthorized = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
#else
        let micAuthorized = true
#endif

        return speechAuthorized && micAuthorized
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
            throw NSError(domain: "SpeechPractice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available right now."])
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            speechRecognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal else { return }
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
                issues.append(GrammarIssue(message: "Sentence should start with a capital letter.", snippet: normalized))
            }

            if let last = normalized.last, ![".", "!", "?"].contains(last) {
                issues.append(GrammarIssue(message: "Sentence may be missing ending punctuation.", snippet: normalized))
            }

            let words = normalized.split(separator: " ").map(String.init)
            if words.count < 3 {
                issues.append(GrammarIssue(message: "Sentence may be too short or a fragment.", snippet: normalized))
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
}

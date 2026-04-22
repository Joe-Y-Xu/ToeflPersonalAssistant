//
//  ContentView.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/21.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SpeechPracticeViewModel()
    @State private var selectedRecord: SpeechRecord?

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    Section("Recording Feature") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TOEFL Speaking Practice")
                                .font(.title2.bold())
                            Text("Record one speech for up to \(Int(viewModel.maxDuration)) seconds, then get grammar issue suggestions.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text("Time: \(viewModel.elapsedTime, specifier: "%.1f")s / \(Int(viewModel.maxDuration))s")
                                .monospacedDigit()
                                .font(.headline)

                            HStack(spacing: 12) {
                                Button {
                                    viewModel.startRecording()
                                } label: {
                                    Label("Start Recording", systemImage: "record.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isRecording || viewModel.isAnalyzing)

                                Button {
                                    viewModel.stopRecordingAndAnalyze()
                                } label: {
                                    Label("Stop & Analyze", systemImage: "stop.circle")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.isRecording)
                            }

                            if viewModel.isAnalyzing {
                                ProgressView("Analyzing...")
                            } else {
                                Text(viewModel.statusText)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            if let errorText = viewModel.errorText {
                                Text(errorText)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            if viewModel.permissionsDenied {
                                Button {
                                    viewModel.openPrivacySettings()
                                } label: {
                                    Label("Open Privacy Settings", systemImage: "gearshape")
                                }
                                .buttonStyle(.bordered)
                            }

                            if !viewModel.latestTranscript.isEmpty {
                                GroupBox("Latest Transcript") {
                                    Text(viewModel.latestTranscript)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            if !viewModel.latestIssues.isEmpty {
                                GroupBox("Detected Grammar Issues") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(viewModel.latestIssues) { issue in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("• \(issue.message)")
                                                if !issue.snippet.isEmpty {
                                                    Text("\"\(issue.snippet)\"")
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .font(.footnote)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Recording History Feature") {
                        if viewModel.history.isEmpty {
                            Text("No recordings yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.history) { record in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(record.createdAt, format: .dateTime.month().day().year()) \(record.createdAt, format: .dateTime.hour().minute())")
                                        Text("Duration: \(record.duration, specifier: "%.1f")s | Issues: \(record.issues.count)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 8) {
                                        Button("Review") {
                                            selectedRecord = record
                                        }
                                        .buttonStyle(.bordered)

                                        Button(role: .destructive) {
                                            viewModel.deleteRecord(id: record.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
                .disabled(selectedRecord != nil)
            }
            .navigationTitle("Speech Coach")
            .toolbar {
                ToolbarItem {
                    if !viewModel.history.isEmpty {
                        Button("Clear") {
                            viewModel.clearHistory()
                        }
                    }
                }
            }

            if let record = selectedRecord {
                HistoryRecordDetailView(record: record) {
                    selectedRecord = nil
                }
                .zIndex(1)
            }
        }
    }
}

private struct HistoryRecordDetailView: View {
    let record: SpeechRecord
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    Text("Created: \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Duration: \(record.duration, specifier: "%.1f") seconds")
                    Text("Grammar issues: \(record.issues.count)")
                }

                Section("Transcript") {
                    Text(record.transcript)
                }

                Section("Grammar Issues") {
                    if record.issues.isEmpty {
                        Text("No issues found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(record.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.message)
                                if !issue.snippet.isEmpty {
                                    Text("\"\(issue.snippet)\"")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Record Detail")
            .toolbar {
                ToolbarItem {
                    Button("Close") {
                        onClose()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}

#Preview {
    ContentView()
}

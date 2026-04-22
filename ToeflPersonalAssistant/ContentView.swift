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
        NavigationView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("TOEFL Speaking Practice")
                        .font(.title2.bold())
                    Text("Record one speech for up to \(Int(viewModel.maxDuration)) seconds, then get grammar issue suggestions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
                        .multilineTextAlignment(.center)
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

                List {
                    Section("Recording History") {
                        if viewModel.history.isEmpty {
                            Text("No recordings yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.history) { record in
                                Button {
                                    selectedRecord = record
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.createdAt, style: .date) + Text(" ") + Text(record.createdAt, style: .time)
                                        Text("Duration: \(record.duration, specifier: "%.1f")s | Issues: \(record.issues.count)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .onDelete(perform: viewModel.deleteHistory)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
            .padding()
            .navigationTitle("Speech Coach")
            .toolbar {
                ToolbarItem {
                    EditButton()
                }
                ToolbarItem {
                    if !viewModel.history.isEmpty {
                        Button("Clear") {
                            viewModel.clearHistory()
                        }
                    }
                }
            }
            .sheet(item: $selectedRecord) { record in
                HistoryRecordDetailView(record: record)
            }
        }
    }
}

private struct HistoryRecordDetailView: View {
    let record: SpeechRecord

    var body: some View {
        NavigationView {
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
        }
    }
}

#Preview {
    ContentView()
}

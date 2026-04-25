//
//  ContentView.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/21.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = SpeechPracticeViewModel()
    @State private var selectedRecord: SpeechRecord?
    @State private var showingAttentions = false

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

                                Button {
                                    viewModel.setAttentionModeEnabled(!viewModel.isAttentionModeEnabled)
                                } label: {
                                    Label(
                                        viewModel.isAttentionModeEnabled ? "Attention Mode ON" : "Attention Mode OFF",
                                        systemImage: viewModel.isAttentionModeEnabled ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(viewModel.isAttentionModeEnabled ? .green : .secondary)
                                .disabled(viewModel.isRecording || viewModel.isAnalyzing)
                            }

                            Button {
                                showingAttentions = true
                            } label: {
                                Label(
                                    "Manage (\(viewModel.selectedAttentionStatistics.count) / \(viewModel.selectedIgnoredIssues.count))",
                                    systemImage: "list.bullet.clipboard"
                                )
                            }
                            .buttonStyle(.bordered)

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
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Play Button
                                        Button {
                                            viewModel.toggleLatestRecordingPlayback()
                                        } label: {
                                            Label(
                                                viewModel.isPlayingLatestRecording ? "Stop Playback" : "Play Recording",
                                                systemImage: viewModel.isPlayingLatestRecording ? "stop.fill" : "play.fill"
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        // ✅ REPLACED WITH GRAMMAR CHECK VIEW ✅
                                        GrammarHighlightView(text: viewModel.latestTranscript)
                                            .frame(height: 140)
                                        
                                    }
                                }
                            }
                            
                            if viewModel.isAttentionModeEnabled, !viewModel.latestAttentionOutcomes.isEmpty {
                                GroupBox("Attention Review") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(viewModel.latestAttentionOutcomes) { outcome in
                                            HStack(alignment: .top, spacing: 10) {
                                                Image(systemName: outcome.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                                    .foregroundStyle(outcome.status == .failed ? .red : .green)

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(outcome.title)
                                                    Text(outcome.status == .failed ? "Still appeared in this recording." : "Improved in this recording.")
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)

                                                    if let matchingIssue = outcome.matchingIssue, !matchingIssue.snippet.isEmpty {
                                                        Text("\"\(matchingIssue.snippet)\"")
                                                            .font(.footnote)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if !viewModel.latestIssues.isEmpty {
                                GroupBox("Detected Grammar Issues") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(viewModel.latestIssues) { issue in
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(issue.message)
                                                    .lineLimit(nil)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                
                                                // Only show buttons if it's a grammar error (starts with "*" and not the revised version)
                                                if issue.message.starts(with: "*") && !issue.message.contains("TOEFL 6.0 Revised Version") {
                                                    HStack(spacing: 8) {
                                                        Spacer()
                                                        
                                                        // 🎯 MARK AS ATTENTION (toggle)
                                                        Button {
                                                            viewModel.toggleAttentionSelection(for: issue)
                                                        } label: {
                                                            Label(
                                                                viewModel.isAttentionSelected(issue) ? "Watched" : "Watch",
                                                                systemImage: viewModel.isAttentionSelected(issue) ? "star.fill" : "star"
                                                            )
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .tint(viewModel.isAttentionSelected(issue) ? .indigo : nil)
                                                        .controlSize(.small)
                                                        
                                                        // 🙈 IGNORE BUTTON
                                                        Button {
                                                            viewModel.toggleIgnoreSelection(for: issue)
                                                        } label: {
                                                            Label(
                                                                viewModel.isIgnored(issue) ? "Ignored" : "Ignore",
                                                                systemImage: viewModel.isIgnored(issue) ? "eye.slash.fill" : "eye.slash"
                                                            )
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .tint(.gray)
                                                        .controlSize(.small)
                                                        .disabled(viewModel.isAttentionSelected(issue))
                                                    }
                                                }
                                            }
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
                                        if record.attentionModeEnabled {
                                            Text("Attention review: \(record.attentionOutcomes.filter { $0.status == .passed }.count) pass / \(record.attentionOutcomes.filter { $0.status == .failed }.count) fail")
                                                .font(.footnote)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    HStack(spacing: 8) {
                                        Button {
                                            viewModel.togglePlayback(for: record)
                                        } label: {
                                            Label(
                                                viewModel.isPlaying(record: record) ? "Stop" : "Play",
                                                systemImage: viewModel.isPlaying(record: record) ? "stop.fill" : "play.fill"
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!viewModel.isPlaybackAvailable(for: record))

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
                ToolbarItemGroup {
                    if !viewModel.selectedAttentionStatistics.isEmpty || !viewModel.selectedIgnoredIssues.isEmpty {
                        Button("Manage") {
                            showingAttentions = true
                        }
                    }

                    if !viewModel.history.isEmpty {
                        Button("Clear") {
                            viewModel.clearHistory()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAttentions) {
                AttentionSummaryView(viewModel: viewModel)
            }

            if let record = selectedRecord {
                HistoryRecordDetailView(record: record, viewModel: viewModel) {
                    selectedRecord = nil
                }
                .zIndex(1)
            }
        }
        .alert("Clear All History?", isPresented: $viewModel.showClearHistoryAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                viewModel.confirmClearHistory()
            }
        } message: {
            Text("Are you sure you want to delete all history? This cannot be undone.")
        }
    }
    
}

private struct AttentionSummaryView: View {
    @ObservedObject var viewModel: SpeechPracticeViewModel
    @Environment(\.dismiss) private var dismiss
    // 👇 保存你勾选的项目
    @State private var selectedItems: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Attention Mode") {
                    Toggle(
                        "Track only selected attentions after each recording",
                        isOn: Binding(
                            get: { viewModel.isAttentionModeEnabled },
                            set: { viewModel.setAttentionModeEnabled($0) }
                        )
                    )
                }

                Section("Selected Attentions") {
                    if viewModel.selectedAttentionStatistics.isEmpty {
                        Text("No attentions selected yet. Turn on an issue from the latest analysis to memorize it.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.selectedAttentionStatistics) { statistic in
                            HStack(alignment: .center, spacing: 12) {
                                
                                // ✅ 可点击的勾选框
                                Button {
                                    if selectedItems.contains(statistic.issueKey) {
                                        selectedItems.remove(statistic.issueKey)
                                    } else {
                                        selectedItems.insert(statistic.issueKey)
                                    }
                                } label: {
                                    Image(systemName: selectedItems.contains(statistic.issueKey) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(statistic.title)
                                    Text("Pass: \(statistic.passCount)   Fail: \(statistic.failCount)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section("Ignored Issues") {
                    if viewModel.selectedIgnoredIssues.isEmpty {
                        Text("No ignored issues yet. Turn on Ignore for an issue to hide it from future analysis.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.selectedIgnoredIssues) { item in
                            HStack(alignment: .center, spacing: 12) {
                                
                                // ✅ SAME CHECKBOX as Attention section
                                Button {
                                    if selectedItems.contains(item.issueKey) {
                                        selectedItems.remove(item.issueKey)
                                    } else {
                                        selectedItems.insert(item.issueKey)
                                    }
                                } label: {
                                    Image(systemName: selectedItems.contains(item.issueKey) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    Text("Ignored in future analysis until turned off")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Issues")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                // ✅ 只删除选中的项目
                if !viewModel.selectedAttentionStatistics.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear Selected") {
                            for key in selectedItems {
                                viewModel.removeAttention(issueKey: key)
                            }
                            selectedItems.removeAll()
                        }
                        .disabled(selectedItems.isEmpty)
                    }
                }
//
//                if !viewModel.selectedIgnoredIssues.isEmpty {
//                    ToolbarItem {
//                        Button("Clear Ignores") {
//                            viewModel.clearAllIgnoredIssues()
//                        }
//                    }
//                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

private struct HistoryRecordDetailView: View {
    let record: SpeechRecord
    @ObservedObject var viewModel: SpeechPracticeViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    Text("Created: \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Duration: \(record.duration, specifier: "%.1f") seconds")
                    Text("Grammar issues: \(record.issues.count)")
                    Text("Attention Mode A: \(record.attentionModeEnabled ? "On" : "Off")")
                }

                Section("Transcript") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            viewModel.togglePlayback(for: record)
                        } label: {
                            Label(
                                viewModel.isPlaying(record: record) ? "Stop Playback" : "Play Recording",
                                systemImage: viewModel.isPlaying(record: record) ? "stop.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.isPlaybackAvailable(for: record))

                        Text(record.transcript)
                    }
                }

                if record.attentionModeEnabled {
                    Section("Attention Review") {
                        if record.attentionOutcomes.isEmpty {
                            Text("No selected attentions were available for this recording.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(record.attentionOutcomes) { outcome in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: outcome.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(outcome.status == .failed ? .red : .green)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(outcome.title)
                                        Text(outcome.status == .failed ? "Failed" : "Passed")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
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

// NATIVE MAC TEXT VIEW — RIGHT-CLICK COPY PERFECT
struct NativeMacTextView: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        return textView
    }
    
    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.string = text
    }
}


// Native Mac Text View with REAL-TIME GRAMMAR & SPELLING CHECK
// ✅ PERFECT, NO ERRORS, MAC NATIVE TEXT VIEW
struct NativeTextView: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        
        // ✅ Enable spelling & grammar (CORRECT MAC CODE)
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        
        // Style
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(
            red: 0.9, green: 0.9, blue: 0.9, alpha: 0.1
        )
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.wantsLayer = true
        textView.layer?.cornerRadius = 6
        
        return textView
    }
    
    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
        
    }
    
    
}

#Preview {
    ContentView()
}

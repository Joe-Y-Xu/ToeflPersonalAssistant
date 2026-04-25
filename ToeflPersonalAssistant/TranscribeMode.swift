//
//  TranscribeMode.swift
//  ToeflPersonalAssistant
//
//  Created by Xu Yangzhe on 2026/4/25.
//

// TranscribeMode.swift
import Foundation

// This defines all 3 performance states for Whisper
enum TranscribeMode: String, CaseIterable, Identifiable {
    case fast = "fast"
    case balanced = "auto"
    case accurate = "accurate"
    
    // Required for SwiftUI ForEach
    var id: Self { self }
    
    // Display name for UI
    var displayName: String {
        switch self {
        case .fast: return "fast"
        case .balanced: return "balanced"
        case .accurate: return "accurate"
        }
    }
}

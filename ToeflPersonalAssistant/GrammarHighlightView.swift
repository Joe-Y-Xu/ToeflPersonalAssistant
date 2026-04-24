//
//  GrammarHighlightView.swift
//  ToeflPersonalAssistant
//
//  Created by Xuyangzhe on 2025.
//

import SwiftUI
import AppKit

struct GrammarHighlightView: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        
        // Enable native grammar & spelling (WORKS PERFECTLY)
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        
        // UI Style
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.white
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

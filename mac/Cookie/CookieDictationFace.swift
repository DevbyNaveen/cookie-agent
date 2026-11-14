//
//  CookieDictationFace.swift
//  Cookie
//
//  Who is speaking, at a glance: Voice's fluid orb and a label while your own words are being taken
//  (dictate, edit, keep), Cookie's face when Cookie answers. The orb sits left of the notch; the
//  tail of your words sits right of it, so they show even where an app reports no text cursor.
//

import EnkeonVoiceKit
import SwiftUI

enum NotchVoiceFace: Equatable {
    case none, words(label: String), cookie

    static func face(phase: DictationController.Phase, editScope: String?, toMemory: Bool, cookieActive: Bool) -> NotchVoiceFace {
        switch phase {
        case .listening:
            if let editScope { return .words(label: editScope) }
            return .words(label: toMemory ? "Listening, saving to memory" : "Listening")
        case .finishing:
            return .words(label: "Writing")
        case .idle, .done:
            return cookieActive ? .cookie : .none
        }
    }

    /// The last `limit` characters of the words, starting at a word.
    static func tail(_ text: String, limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = String(text.suffix(limit))
        let word = cut.firstIndex(of: " ").map { cut[cut.index(after: $0)...] } ?? Substring(cut)
        return "…" + word
    }
}

/// The closed notch while you dictate: orb and label on the left, your words on the right.
struct DictationLiveActivity: View {
    @ObservedObject var dictation: DictationController
    let label: String
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                FluidOrb(energy: dictation.level, palette: dictation.toMemory ? .memory : .listening)
                    .frame(width: 16, height: 16)
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            Text(NotchVoiceFace.tail(dictation.liveText, limit: 28))
                .font(.system(size: 11)).foregroundStyle(CK.secondary).lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(CK.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(dictation.liveText)")
    }
}

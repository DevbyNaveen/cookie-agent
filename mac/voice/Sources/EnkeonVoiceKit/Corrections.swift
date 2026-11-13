//
//  Corrections.swift
//  EnkeonVoiceKit
//
//  Learning from what the person fixes. After a verified insertion the same
//  field is read again (never another one), only the span Enkeon typed is
//  compared, and a word they replaced with a name or a term ("Halverson" →
//  "Halvorsen") is offered for the dictionary. Nothing is added on its own,
//  and nothing leaves the Mac.
//

import AppKit
import ApplicationServices

public enum Corrections {
    /// Words the person put in place of what was typed, that look like names or terms (a capital or a digit).
    /// Only same-length edits are read: a rewritten sentence says nothing about a misheard word.
    public static func learned(typed: String, edited: String) -> [String] {
        let before = words(typed), after = words(edited)
        guard before.count == after.count, before != after else { return [] }
        var found: [String] = []
        for (old, new) in zip(before, after) where old.lowercased() != new.lowercased() || old != new {
            let looksLikeATerm = new.contains(where: { $0.isUppercase || $0.isNumber })
            guard looksLikeATerm, new.count >= 2, new.count <= 40, !found.contains(new) else { continue }
            found.append(new)
        }
        // A whole sentence re-cased is a style change, not a misheard word.
        return found.count <= 3 ? found : []
    }

    /// What is in the span Enkeon typed now: the field's text minus what was before and after it at key-down.
    /// nil when the text around it changed too (the person edited elsewhere, or it's another document).
    static func span(now: String, before: String, range: CFRange) -> String? {
        let original = before as NSString
        guard range.location >= 0, range.location + range.length <= original.length else { return nil }
        let prefix = original.substring(to: range.location)
        let suffix = original.substring(from: range.location + range.length)
        guard now.hasPrefix(prefix), now.hasSuffix(suffix), (now as NSString).length >= (prefix as NSString).length + (suffix as NSString).length
        else { return nil }
        let current = now as NSString
        return current.substring(with: NSRange(location: (prefix as NSString).length,
                                               length: current.length - (prefix as NSString).length - (suffix as NSString).length))
    }

    private static func words(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Reads the field again at 8 s and 20 s after a verified insertion; the terms the person corrected, once.
    @MainActor
    static func watch(_ destination: TextDestination, typed: String) async -> [String] {
        for delay in [8.0, 12.0] {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return [] }
            guard let now = TextFieldAccess.string(destination.element, kAXValueAttribute),
                  let edited = span(now: now, before: destination.value, range: destination.range) else { return [] }
            let terms = learned(typed: typed, edited: edited)
            if !terms.isEmpty { return terms }
        }
        return []
    }
}

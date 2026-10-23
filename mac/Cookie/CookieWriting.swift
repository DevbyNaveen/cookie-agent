//
//  CookieWriting.swift
//  Cookie
//
//  Writing where you are. Apps you've allowed take Cookie's typing without a
//  card (sending, paying and deleting still ask). What Cookie typed is kept
//  until you move on, and if you changed it before sending, the change is
//  remembered under that Cookie so the next draft sounds more like you.
//

import AppKit
import Foundation

/// The apps Cookie may type into without asking each time (names as macOS shows them).
@MainActor
enum CookieWriteGrants {
    static let key = "cookie.writeApps"
    static let writeTools: Set<String> = ["type_text", "set_value", "replace_selection"]

    static var apps: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func allow(_ app: String) {
        let trimmed = app.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !apps.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        UserDefaults.standard.set(apps + [trimmed], forKey: key)
    }

    static func forget(_ app: String) {
        UserDefaults.standard.set(apps.filter { $0.caseInsensitiveCompare(app) != .orderedSame }, forKey: key)
    }

    static func allows(appName: String?, bundleID: String?, apps: [String]) -> Bool {
        let names = [appName, bundleID].compactMap { $0?.lowercased() }
        return apps.contains { app in
            let app = app.lowercased()
            return names.contains { $0 == app || $0.hasSuffix("." + app) }
        }
    }

    /// Whether every action on the card is typing into an allowed app (or a task whose
    /// apps are all allowed), with no value the person didn't write.
    static func covers(_ approval: HarnessApproval, frontAppName: String?, frontBundleID: String?, apps: [String]) -> Bool {
        guard !apps.isEmpty else { return false }
        return approval.actions.allSatisfy { action in
            guard action.fromData.isEmpty else { return false }
            if action.tool == "start_task" {
                let wanted = (MacOperator.args(of: action)["apps"] as? String ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return !wanted.isEmpty && wanted.allSatisfy { allows(appName: $0, bundleID: nil, apps: apps) }
            }
            return writeTools.contains(action.tool) && allows(appName: frontAppName, bundleID: frontBundleID, apps: apps)
        }
    }
}

/// What Cookie typed, where, for whom: compared with the field later to learn from edits.
struct CookieTypedDraft: Equatable {
    let app: String
    let text: String
    let date: Date
    let threadID: UUID?
}

enum CookieCorrections {
    /// Nothing to learn from a tiny field, an unrelated field, or a draft left as it was.
    static func isEdit(before: String, after: String) -> Bool {
        let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before.count >= 20, after.count >= 10, before != after else { return false }
        let similarity = wordOverlap(before, after)
        return similarity >= 0.4 && similarity < 1
    }

    /// Share of the typed draft's words still present after editing, 0…1.
    static func wordOverlap(_ before: String, _ after: String) -> Double {
        let beforeWords = words(before), afterWords = Set(words(after))
        guard !beforeWords.isEmpty else { return 0 }
        let kept = beforeWords.filter { afterWords.contains($0) }.count
        return Double(kept) / Double(beforeWords.count)
    }

    /// One sentence a later draft can learn from: what was dropped, what was added.
    static func summary(before: String, after: String, app: String) -> String? {
        guard isEdit(before: before, after: after) else { return nil }
        let removed = sentences(before).filter { !sentences(after).contains($0) }
        let added = sentences(after).filter { !sentences(before).contains($0) }
        var parts: [String] = []
        if !removed.isEmpty { parts.append("dropped " + removed.prefix(2).map { "“\($0.prefix(90))”" }.joined(separator: " and ")) }
        if !added.isEmpty { parts.append("wrote " + added.prefix(2).map { "“\($0.prefix(90))”" }.joined(separator: " and ")) }
        guard !parts.isEmpty else { return nil }
        let lengthNote = after.count < Int(Double(before.count) * 0.7) ? "; shorter than Cookie's draft" : after.count > Int(Double(before.count) * 1.4) ? "; longer than Cookie's draft" : ""
        return "In \(app) the person edited Cookie's draft: \(parts.joined(separator: ", "))\(lengthNote)."
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }

    private static func sentences(_ text: String) -> [String] {
        text.split { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 }
    }
}

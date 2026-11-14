//
//  CookieDictation.swift
//  Cookie
//
//  Enkeon dictation inside Cookie: one DictationController (EnkeonVoiceKit) owns the keyboard tap
//  and types your words. Cookie listens on the same tap (`controller.shortcuts`) for Talk, hover
//  and conversation, and steps aside for every dictation chord.
//

import EnkeonVoiceKit
import Foundation

@MainActor
final class CookieDictation {
    static let shared = CookieDictation()
    let controller = DictationController()

    /// Needs Accessibility and Input Monitoring; called again by the permission poller once granted.
    func start() { controller.start() }
    func stop() { controller.stop() }
}

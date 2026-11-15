//
//  CookieFullAccess.swift
//  Cookie
//
//  Settings → Privacy & safety → Full access. On, Cookie answers every card
//  yes for you: opening, typing, Mac actions, and sending or deleting in your
//  connected apps. Each one still lands in Privacy Proof, so you can see what ran.
//

import Foundation

enum CookieFullAccess {
    static let key = "cookie.fullAccess"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Says yes to the card when Full access is on. True when it answered.
    @MainActor static func answers(_ approval: HarnessApproval?, with client: HarnessClient, feature: String) -> Bool {
        guard isOn, let approval else { return false }
        for action in approval.actions {
            CookieProof.shared.record(.acted, feature: feature,
                                      summary: "Full access: \(action.tool) \(action.preview)".prefix(160).description)
        }
        client.approve(approval, allow: true)
        return true
    }
}

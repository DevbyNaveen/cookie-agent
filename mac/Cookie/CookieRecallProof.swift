import Foundation

/// What Enkeon checked about one recalled memory before handing it over: its `proof` on a recall
/// hit. Older engines send none, and then Cookie shows no mark at all — a missing check is never
/// drawn as a passed one.
enum CookieRecallProof: String, Equatable {
    /// The words still match the source they were taken from.
    case sourceMatched = "source_matched"
    /// No source to re-read, but the saved memory is byte-for-byte as it was saved.
    case savedIntact = "saved_intact"
    /// The source has changed since the memory was taken from it.
    case sourceChanged = "source_changed"
    /// Nothing was checked.
    case unchecked

    static let changedSuffix = " · source changed"

    /// A recall hit's proof; nil when the hit carries none. A state Cookie doesn't know counts as unchecked.
    static func of(_ hit: [String: Any]) -> CookieRecallProof? {
        guard let proof = hit["proof"] as? [String: Any] else { return nil }
        return (proof["state"] as? String).flatMap(Self.init(rawValue:)) ?? .unchecked
    }

    /// One mark for several hits: any changed source wins, then the weaker of the two checks;
    /// one unchecked (or proof-less) hit means no mark, so a check never covers a line it didn't.
    static func combined(_ proofs: [CookieRecallProof?]) -> CookieRecallProof? {
        guard !proofs.isEmpty else { return nil }
        if proofs.contains(.sourceChanged) { return .sourceChanged }
        if proofs.contains(where: { $0 == nil || $0 == .unchecked }) { return nil }
        return proofs.contains(.savedIntact) ? .savedIntact : .sourceMatched
    }

    /// The SF Symbol for the card's footer; nil for unchecked, which shows nothing.
    var symbol: String? {
        switch self {
        case .sourceMatched: "checkmark.seal"
        case .savedIntact: "lock.doc"
        case .sourceChanged: "exclamationmark.triangle"
        case .unchecked: nil
        }
    }

    /// Exactly what was checked, for VoiceOver and the hover help.
    var explanation: String? {
        switch self {
        case .sourceMatched: "Source matched: Enkeon re-read the source and it still says this."
        case .savedIntact: "Saved intact: there was no source to re-read, but the memory is unchanged since it was saved."
        case .sourceChanged: "Source changed: the source has changed since this was remembered, so it may be out of date."
        case .unchecked: nil
        }
    }
}

import Foundation

/// The exact replacement span, decided before transcription/model work. UTF-16
/// coordinates match Accessibility, including emoji and composed characters.
struct VoiceEditPlan: Equatable {
    enum Scope: String { case selection = "Editing selection", message = "Editing message" }
    let text: String
    let range: NSRange
    let scope: Scope
    static let maximumLength = 6_000

    init?(value: String, selection: CFRange) {
        let count = value.utf16.count
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location else { return nil }
        scope = selection.length > 0 ? .selection : .message
        range = scope == .selection ? NSRange(location: selection.location, length: selection.length)
            : NSRange(location: 0, length: count)
        text = (value as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    }
}

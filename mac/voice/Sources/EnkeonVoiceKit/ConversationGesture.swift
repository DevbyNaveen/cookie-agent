//
//  ConversationGesture.swift
//  EnkeonVoiceKit (from Cookie's conversation mode)
//
//  ⌥⌘ pressed and let go with nothing else in between: a tap, which turns conversation on or off.
//

public struct ConversationGesture {
    public private(set) var held = false
    private var usedByShortcut = false
    public init() {}
    public mutating func reset() { held = false; usedByShortcut = false }
    public mutating func update(held next: Bool, otherKey: Bool = false) -> Bool {
        if next {
            if !held { usedByShortcut = false }
            held = true
            usedByShortcut = usedByShortcut || otherKey
            return false
        }
        let toggle = held && !usedByShortcut && !otherKey
        reset()
        return toggle
    }
}

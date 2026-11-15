import EnkeonVoiceKit

enum CookieDictationCorrectionTests {
    static func run() {
        precondition(DictationText.correctionInstruction("no, make it Tuesday") != nil)
        precondition(DictationText.correctionInstruction("Actually: change that to Friday") != nil)
        precondition(DictationText.correctionInstruction("Correction replace it with the new title") != nil)
        precondition(DictationText.correctionInstruction("Make it clear we ship Friday") == nil)
        precondition(DictationText.correctionInstruction("Make it Tuesday") == nil)
        print("5 dictation correction checks passed.")
    }
}

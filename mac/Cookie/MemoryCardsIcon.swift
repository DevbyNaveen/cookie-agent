import SwiftUI

/// One shared saved-cards mark for the launcher and Memory panel.
struct MemoryCardsIcon: View {
    var body: some View {
        Image(systemName: "square.stack")
            .resizable().scaledToFit()
            .accessibilityHidden(true)
    }
}

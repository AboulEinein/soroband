import SwiftUI

enum MenuBar {
    /// What the menu bar item shows.
    static var text: String { "Soroband \(Core.version)" }
}

struct MenuBarLabel: View {
    let text: String

    var body: some View {
        Text(text)
    }
}

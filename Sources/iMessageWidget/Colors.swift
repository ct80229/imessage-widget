import SwiftUI

// Apple HIG system gray scale — dark mode values
// https://developer.apple.com/design/human-interface-guidelines/color#Specifications
//
// Semantic role in this widget:
//   gray5  (#1C1C1E) — widget background     (≈ systemBackground)
//   gray4  (#2C2C2E) — card fill             (≈ secondarySystemBackground)
//   gray3  (#3A3A3C) — input fields, dividers (≈ tertiarySystemBackground)
//   gray2  (#48484A) — borders, badges
//   gray   (#636366) — secondary / tertiary labels

extension Color {
    static let systemGray5 = Color(red: 28/255, green: 28/255, blue: 30/255)  // #1C1C1E
    static let systemGray4 = Color(red: 44/255, green: 44/255, blue: 46/255)  // #2C2C2E
    static let systemGray3 = Color(red: 58/255, green: 58/255, blue: 60/255)  // #3A3A3C
    static let systemGray2 = Color(red: 72/255, green: 72/255, blue: 74/255)  // #48484A
    static let systemGray  = Color(red: 99/255, green: 99/255, blue: 102/255) // #636366
}

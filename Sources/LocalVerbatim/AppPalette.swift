import SwiftUI
import AppKit

enum AppPalette {
    static let accent = Color(nsColor: NSColor(name: "LocalVerbatimGreen") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.76, blue: 0.66, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.42, blue: 0.36, alpha: 1)
    })
    static let paper = Color(nsColor: NSColor(name: "LocalVerbatimPaper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 0.975, green: 0.973, blue: 0.96, alpha: 1)
    })
}

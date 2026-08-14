import SwiftUI
import AppKit

/// SwiftUI bridging for the UI-agnostic Domain color.
/// Lives in Presentation so the Domain layer stays free of SwiftUI.
extension AnnotationColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent),
                  green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent),
                  alpha: Double(ns.alphaComponent))
    }
}

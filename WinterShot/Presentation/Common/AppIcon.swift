import AppKit

/// The bundled AppIcon, exposed for in-app use (menu bar, placeholders,
/// titlebar). The asset catalog compiles it into the bundle, so
/// `NSImage(named:)` resolves it at runtime.
enum AppIcon {
    static let full: NSImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage

    /// A copy sized for the menu bar. Sized on a copy so the shared
    /// application icon instance is left untouched.
    static let menuBar: NSImage = resized(to: 18)

    private static func resized(to points: CGFloat) -> NSImage {
        guard let copy = full.copy() as? NSImage else { return full }
        copy.size = NSSize(width: points, height: points)
        return copy
    }
}

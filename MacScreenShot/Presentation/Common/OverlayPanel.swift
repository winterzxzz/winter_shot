import AppKit

/// Borderless full-screen panel used by the capture selection overlays.
/// Borderless windows refuse key status by default; the overlays need it
/// so Esc can cancel.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

import Foundation
import ServiceManagement

/// Launch at login, backed by `SMAppService`.
///
/// macOS owns the truth here — the same switch lives in System Settings →
/// General → Login Items & Extensions, and the user can flip it there or
/// deny the registration outright. So nothing is mirrored into UserDefaults:
/// the state is always read back from the service, and the Settings toggle
/// reflects whatever the system currently says.
@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()

    /// The system's current registration state for this app.
    @Published private(set) var status: SMAppService.Status

    /// Set when register/unregister throws, so Settings can say what went
    /// wrong instead of silently snapping the toggle back.
    @Published private(set) var errorMessage: String?

    private init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS can park a registration behind an explicit approval — the item
    /// exists but stays disabled until the user allows it in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
        if status == .enabled || status == .notRegistered { errorMessage = nil }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Opens the Login Items pane, for when macOS wants the registration
    /// approved there.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

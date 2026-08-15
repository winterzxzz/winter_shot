import Foundation

/// Records the screen to a raw video plus an input-event sidecar.
/// Implemented in the Data layer (ScreenCaptureKit + AVFoundation).
@MainActor
protocol ScreenRecorder: AnyObject {
    var isRecording: Bool { get }
    /// Starts capturing the display under the cursor. The system cursor is
    /// excluded from the pixels; its motion is logged for synthetic rendering.
    func start() async throws
    /// Stops capture and returns the finished recording with its event log.
    func stop() async throws -> (Recording, RecordingEventLog)
}

/// Renders a raw recording into a polished video: backdrop, rounded corners,
/// auto-zoom on clicks, smoothed synthetic cursor, click ripples.
protocol RecordingRenderer {
    func export(recording: Recording,
                events: RecordingEventLog,
                options: RecordingExportOptions,
                to destination: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws
}

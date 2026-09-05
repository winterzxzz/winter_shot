import SwiftUI

/// Detail pane for a recording in the main window. The studio editor is a
/// window of its own (it wants the whole screen), so this pane shows the
/// take — a poster frame, its length and size — and opens it.
struct RecordingDetailView: View {
    let recording: Recording
    let onOpen: () -> Void
    let onReveal: () -> Void

    @State private var poster: RecordingPoster?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            posterView
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    Label("Open in Studio Editor", systemImage: "movieclapper")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button(action: onReveal) {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
            .controlSize(.large)
            Text("Zoom, cursor, backdrop and masks are edited in the studio window. Your edits are saved next to the recording and come back when you reopen it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: recording.videoURL) {
            poster = await RecordingPoster.load(for: recording.videoURL,
                                                maxSize: CGSize(width: 1800, height: 1200))
        }
    }

    private var posterView: some View {
        Group {
            if let image = poster?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.primary.opacity(0.06))
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: 900, maxHeight: 560)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) {
            if let duration = poster?.duration, duration > 0 {
                Label(RecordingPoster.label(seconds: duration), systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(10)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .help("Double-click to open in the studio editor")
    }

    private var title: String {
        "Recording " + recording.createdAt.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
    }

    private var subtitle: String {
        var parts: [String] = []
        let duration = poster?.duration ?? recording.duration
        if duration > 0 { parts.append(RecordingPoster.label(seconds: duration)) }
        let size = recording.frameSize != .zero
            ? recording.frameSize
            : poster?.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if size != .zero { parts.append("\(Int(size.width))×\(Int(size.height))") }
        parts.append(recording.filename)
        return parts.joined(separator: " · ")
    }
}

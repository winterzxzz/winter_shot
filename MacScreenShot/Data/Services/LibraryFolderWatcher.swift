import Foundation

/// Watches the captures folder so a change made outside the app — a capture
/// deleted or dropped in from Finder — reaches the library without a manual
/// refresh. Posts `.winterShotLibraryChanged`, the same notification the
/// app's own captures and deletes send.
final class LibraryFolderWatcher {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.winterzxzz.WinterShot.library-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var knownNames: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.knownNames = self.captureNames()
            self.arm()
        }
    }

    private func arm() {
        source?.cancel()
        source = nil
        // The user may have removed the folder itself; put it back so the
        // next capture has somewhere to go and there is something to watch.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The folder was trashed or moved: this descriptor now
                // follows it there, so watch the real location again.
                self.arm()
            }
            self.scheduleCheck()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Finder deletes a selection file by file; wait for the burst to end.
    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func check() {
        let names = captureNames()
        defer { knownNames = names }
        let removed = !knownNames.subtracting(names).isEmpty
        // A new movie is left to the recorder to announce — it sits in the
        // folder, unfinished, for as long as the recording runs.
        let addedImage = names.subtracting(knownNames).contains { $0.hasSuffix(".png") }
        guard removed || addedImage else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .winterShotLibraryChanged, object: nil)
        }
    }

    /// The files the library lists — sidecar writes never count as a change.
    private func captureNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.map { $0.lowercased() }.filter { $0.hasSuffix(".png") || $0.hasSuffix(".mp4") })
    }
}

import Foundation
import UniformTypeIdentifiers

/// A row dragged out of the list of videos, as the sidebar receives it: which video, and from
/// which playlist, so a drop moves it there rather than listing a copy.
///
/// Handed out as a type only Driftcast knows, not as the file itself: as a file, a row dropped
/// on the Finder or the desktop would have copied the film there, or moved it on the same
/// disk. The type is what lets the sidebar know such a drag; which rows it carries is noted
/// here as the drag begins (`takePending`), because the data could not be read back from the
/// drop (see `pending`).
struct DraggedVideo: Codable, Hashable {
    var playlist: Playlist.ID
    var item: MediaItem.ID

    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let typeIdentifier = "com.leechsoftware.driftcast.video"
    static let type = UTType(exportedAs: typeIdentifier)

    /// The rows of the drag under way, noted as it begins. Read at the drop instead of the
    /// drag pasteboard: by the time a drop's providers are asked for their data, macOS has
    /// ended the drag and the read comes back cancelled (NSCocoaError 3072, 2026-11-20).
    private static let lock = NSLock()
    private static var pending: [DraggedVideo] = []
    private static var pendingSince = Date.distantPast

    private static func note(_ row: DraggedVideo) {
        lock.lock(); defer { lock.unlock() }
        // Rows asked for together belong to one drag; a pause means a new one.
        if Date().timeIntervalSince(pendingSince) > 1 { pending = [] }
        pendingSince = Date()
        if !pending.contains(row) { pending.append(row) }
    }

    /// The rows of the drag that just ended, once.
    static func takePending() -> [DraggedVideo] {
        lock.lock(); defer { lock.unlock() }
        let rows = pending
        pending = []
        return rows
    }

    func itemProvider() -> NSItemProvider {
        Self.note(self)
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .all) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// The rows in a drop, read on whatever thread the providers answer on.
    static func load(from providers: [NSItemProvider], then finish: @escaping @Sendable ([DraggedVideo]) -> Void) {
        let ours = providers.filter { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [DraggedVideo] = []
        for provider in ours {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                if let data, let row = try? JSONDecoder().decode(DraggedVideo.self, from: data) {
                    lock.lock(); found.append(row); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { finish(found) }
    }

    /// The files in a drop from the Finder or another app, in the order they were given.
    static func loadFiles(from providers: [NSItemProvider], then finish: @escaping @Sendable ([URL]) -> Void) {
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (n, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); found.append((n, url)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { finish(found.sorted { $0.0 < $1.0 }.map(\.1)) }
    }
}

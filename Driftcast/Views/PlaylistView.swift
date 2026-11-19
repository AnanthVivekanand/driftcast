import SwiftUI

struct PlaylistView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlaybackController
    @State private var selection = Set<MediaItem.ID>()
    /// Videos waiting for the person to confirm that their files should go to the Trash.
    @State private var filesToDelete: [MediaItem] = []
    @State private var deleteProblem: String?
    @AppStorage(Prefs.showDetails) private var showDetails = false

    var body: some View {
        if let playlist = library.selectedPlaylist {
            List(selection: $selection) {
                ForEach(playlist.items) { item in
                    MediaRow(item: item, isCurrent: player.nowPlaying?.id == item.id)
                        .tag(item.id)
                }
                .onMove { library.move(in: playlist.id, from: $0, to: $1) }
            }
            .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
                contextMenu(ids, in: playlist)
            } primaryAction: { ids in
                if let item = playlist.items.first(where: { ids.contains($0.id) }) {
                    player.play(item, queue: playlist.items)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                !library.add(urls, to: playlist.id).isEmpty
            }
            .onDeleteCommand { library.remove(selection, from: playlist.id) }
            .onChange(of: selection) { ids in
                // The details panel follows the selection; with nothing selected it shows the
                // playing video.
                if let item = playlist.items.first(where: { ids.contains($0.id) }) { player.infoItem = item }
            }
            .modifier(ListKeys(onSpace: { player.togglePause() }, onReturn: {
                guard let item = playlist.items.first(where: { selection.contains($0.id) }) else { return false }
                player.play(item, queue: playlist.items)
                return true
            }))
            .overlay {
                if playlist.items.isEmpty {
                    EmptyStateView(title: "Drop Videos Here", systemImage: "film.stack",
                                   message: "Drag in files or folders, or click the + button. MKV, MP4, AVI, MOV and most other formats work.") {
                        Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
                    }
                }
            }
            .alert(filesToDelete.count == 1 ? "Do you really want to delete this file?" : "Do you really want to delete these \(filesToDelete.count) files?",
                   isPresented: Binding(get: { !filesToDelete.isEmpty }, set: { if !$0 { filesToDelete = [] } }),
                   presenting: filesToDelete) { items in
                Button("Move to Trash", role: .destructive) { deleteFiles(items) }
                Button("Cancel", role: .cancel) {}
            } message: { items in
                if items.count == 1 {
                    Text("“\(items[0].url.lastPathComponent)” will be moved to the Trash and taken out of your playlists. You can get it back from the Trash.")
                } else {
                    Text("The files will be moved to the Trash and taken out of your playlists. You can get them back from the Trash.")
                }
            }
            .alert("Some files couldn't be deleted", isPresented: Binding(get: { deleteProblem != nil }, set: { if !$0 { deleteProblem = nil } })) {
                Button("OK") {}
            } message: {
                Text(deleteProblem ?? "")
            }
            .navigationTitle(playlist.name)
            .navigationSubtitle(playlist.items.count == 1 ? "1 video" : "\(playlist.items.count) videos")
            .toolbar {
                // Beside the playlist's name, the list it adds to, rather than with the
                // playback controls on the right.
                ToolbarItem(placement: .navigation) {
                    Button { library.presentOpenPanel(into: playlist.id) } label: {
                        Label("Add Videos", systemImage: "plus")
                    }
                    .help("Add videos or folders")
                }
                ToolbarItem(placement: .primaryAction) {
                    OutputPicker()
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showDetails) {
                        Label("Details", systemImage: "sidebar.trailing")
                    }
                    .help("Show the poster, plot, ratings and file details")
                }
            }
        } else {
            EmptyStateView(title: "No Playlist Selected", systemImage: "list.bullet.rectangle")
        }
    }

    /// After the confirmation: a playing video is stopped first, so its file isn't open while
    /// it moves, then the files go to the Trash.
    private func deleteFiles(_ items: [MediaItem]) {
        if let current = player.nowPlaying, items.contains(where: { $0.url == current.url }) { player.stop() }
        let failed = library.deleteFiles(items.map(\.url))
        selection.subtract(items.map(\.id))
        if !failed.isEmpty {
            failed.forEach { ErrorLog.record("Delete File", $0.0.path, error: $0.1) }
            deleteProblem = failed.map { "\($0.0.lastPathComponent): \($0.1.localizedDescription)" }.joined(separator: "\n")
        }
    }

    /// Right-click menu for the playlist: the commands from the menu bar and toolbar that
    /// apply to the clicked videos, so nothing needs hunting for.
    @ViewBuilder
    private func contextMenu(_ ids: Set<MediaItem.ID>, in playlist: Playlist) -> some View {
        let items = playlist.items.filter { ids.contains($0.id) }
        if let item = items.first {
            let isCurrent = player.nowPlaying?.id == item.id
            if isCurrent {
                Button(player.isPlaying ? "Pause" : "Resume") { player.togglePause() }
                Button("Stop") { player.stop() }
            } else if let resume = library.resumePosition(for: item.url) {
                Button("Resume from \(formatTime(resume))") { player.play(item, queue: playlist.items) }
            } else {
                Button("Play") { player.play(item, queue: playlist.items) }
            }
            Button("Play from Beginning") { player.play(item, queue: playlist.items, fromBeginning: true) }
            if isCurrent {
                Divider()
                Button("Add Subtitle File…") { player.chooseSubtitleFile() }
                Button("Find Subtitles Online…") { player.showSubtitleSearch = true }
            }
            Divider()
            Button("Details") { player.infoItem = item; showDetails = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            Divider()
            if items.contains(where: { library.watched.contains($0.url.path) || library.progress[$0.url.path] != nil }) {
                Button("Mark as Unwatched") { items.forEach { library.clearProgress($0.url) } }
            }
            if items.contains(where: { !library.watched.contains($0.url.path) }) {
                Button("Mark as Watched") { items.forEach { library.markWatched($0.url) } }
            }
            Menu("Move to Playlist") {
                ForEach(library.playlists.filter { $0.id != playlist.id }) { other in
                    Button(other.name) { library.moveItems(ids, from: playlist.id, to: other.id) }
                }
                if library.playlists.count > 1 { Divider() }
                Button("New Playlist") {
                    let source = playlist.id
                    let created = library.newPlaylist()
                    library.moveItems(ids, from: source, to: created)
                }
            }
            Divider()
            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
            Divider()
            Button("Remove from Playlist") { library.remove(ids, from: playlist.id) }
            Button(items.count == 1 ? "Delete File…" : "Delete \(items.count) Files…", role: .destructive) { filesToDelete = items }
        } else {
            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
            Button("New Playlist") { library.newPlaylist() }
        }
    }
}

/// Space and Return on the playlist. `onKeyPress` is macOS 14's way; before it, a key monitor
/// that only acts while a list has the keyboard, so typing in a text field is left alone.
private struct ListKeys: ViewModifier {
    let onSpace: () -> Void
    let onReturn: () -> Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.space) { onSpace(); return .handled }
                .onKeyPress(.return) { onReturn() ? .handled : .ignored }
        } else {
            content.background(ListKeyMonitor(onSpace: onSpace, onReturn: onReturn))
        }
    }
}

private struct ListKeyMonitor: NSViewRepresentable {
    let onSpace: () -> Void
    let onReturn: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onSpace = onSpace
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onSpace = onSpace
        view.onReturn = onReturn
    }

    final class MonitorView: NSView {
        var onSpace: (() -> Void)?
        var onReturn: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.firstResponder is NSTableView,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                switch event.keyCode {
                case 49: self.onSpace?(); return nil
                case 36, 76: return self.onReturn?() == true ? nil : event
                default: return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct MediaRow: View {
    let item: MediaItem
    let isCurrent: Bool
    @EnvironmentObject private var library: Library
    @State private var info: MediaInfo?
    @State private var poster: NSImage?
    @State private var details: MovieDetails?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
                    }
                    TitleLine(title: item.parsedTitle)
                        .fontWeight(isCurrent ? .semibold : .regular)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Watched")
            }
            // The length over the watched bar, both against the right edge, so the bars form
            // one column down the list instead of ending wherever each name ends. Each sits
            // level with a line of text: the length with the name, the bar with the detail line.
            VStack(alignment: .trailing, spacing: 3) {
                Text(length ?? " ")   // a space holds the line until the length is known
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(" ").font(.caption).hidden()
                    .frame(width: WatchedBar.width)
                    .overlay {
                        WatchedBar(fraction: watchedFraction, finished: isWatched)
                            .help(isWatched ? "Watched" : watchedFraction > 0 ? "\(Int((watchedFraction * 100).rounded()))% watched" : "Not watched yet")
                    }
            }
        }
        .padding(.vertical, 3)
        // Finished videos fade back so what's left to watch stands out.
        .opacity(isWatched && !isCurrent ? 0.45 : 1)
        .task(id: item.url) {
            guard item.exists else { failed = true; return }
            do {
                let i = try await MediaProbe.shared.probe(item.url)
                info = i
                if let data = await Thumbnailer.shared.poster(for: item.url, duration: i.duration) {
                    poster = NSImage(data: data)
                }
            } catch {
                failed = true
            }
            // Year and rating for the detail line; cached answers come back at once, new ones
            // are fetched no faster than the services allow.
            details = await MetadataLookup.shared.cached(for: item.url)
            if details == nil, MetadataLookup.isEnabled, !Task.isCancelled {
                details = await MetadataLookup.shared.details(for: item.url)
            }
        }
    }

    private var isWatched: Bool { library.watched.contains(item.url.path) }

    private var length: String? {
        guard let d = info?.duration, d > 0 else { return nil }
        return formatTime(d)
    }

    /// 0 for a video that hasn't been started, 1 for one watched to the end.
    private var watchedFraction: Double {
        isWatched ? 1 : (library.progress[item.url.path]?.fraction ?? 0)
    }

    private var detail: String {
        if !item.exists { return "File not found" }
        if failed { return "Couldn't read this file" }
        guard let info else { return item.url.deletingLastPathComponent().lastPathComponent }
        var parts: [String] = []
        // Watched past the start of the credits: the time still left would only count credits.
        if isWatched {
            parts.append("Finished")
        } else if let p = library.progress[item.url.path] {
            parts.append("\(formatTime(max(0, p.duration - p.position))) left")
        }
        if let details {
            if details.isEpisode {
                // The title line already says "S4 E7"; this line names the episode.
                if let name = details.episodeTitle { parts.append(name) }
            } else if let year = details.year {
                parts.append(String(year))
            }
            if let rating = details.shortRating { parts.append(rating) }
        }
        parts.append(info.summary)
        return parts.joined(separator: " · ")
    }
}

/// The small bar under a video's length showing how much of it has been watched: the accent
/// color while there's more to see, green once it's finished (gray would sink into a finished
/// row's fade and look like an empty bar).
private struct WatchedBar: View {
    static let width: CGFloat = 56
    let fraction: Double
    let finished: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(finished ? Color.green : Color.accentColor)
                .frame(width: Self.width * min(1, max(0, fraction)))
        }
        .frame(width: Self.width, height: 4)
        .accessibilityLabel("Watched")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

import SwiftUI

struct PlaylistView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlaybackController
    @State private var selection = Set<MediaItem.ID>()
    /// Videos waiting for the person to confirm that their files should go to the Trash.
    @State private var filesToDelete: [MediaItem] = []
    @State private var deleteProblem: String?
    /// The video whose title is a text box, and what has been typed into it.
    @State private var editingID: MediaItem.ID?
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool
    /// Whether that text box has had the keyboard yet. Losing the keyboard ends the edit, and
    /// a loss noted before the box ever had it belongs to whatever had it before.
    @State private var titleHadFocus = false
    /// Gives the list the keyboard back when that text box closes.
    @State private var listKeyboard = ListKeyboard()
    @AppStorage(Prefs.showDetails) private var showDetails = true

    var body: some View {
        if let playlist = library.selectedPlaylist {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(playlist.items) { item in
                        MediaRow(item: item, isCurrent: player.nowPlaying?.id == item.id,
                                 titleEditor: editingID == item.id ? AnyView(titleEditor) : nil)
                            .tag(item.id)
                            // Dragged onto a playlist in the sidebar, or below them for a new one.
                            .itemProvider { DraggedVideo(playlist: playlist.id, item: item.id).itemProvider() }
                    }
                    .onMove {
                        // The drag ended here, in the list: its rows go to no playlist.
                        _ = DraggedVideo.takePending()
                        library.move(in: playlist.id, from: $0, to: $1)
                    }
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
                // Not while a title is being typed: Delete then belongs to the text.
                .onDeleteCommand { if editingID == nil { library.remove(selection, from: playlist.id) } }
                .onChange(of: selection) { ids in
                    // The details panel follows the selection; with nothing selected it shows the
                    // playing video.
                    if let item = playlist.items.first(where: { ids.contains($0.id) }) { player.infoItem = item }
                }
                .modifier(ListKeys(isTyping: editingID != nil, onSpace: { player.togglePause() }, onReturn: {
                    guard let item = playlist.items.first(where: { selection.contains($0.id) }) else { return false }
                    player.play(item, queue: playlist.items)
                    return true
                }))
                .background(SelectAllKey { selectAll(in: playlist) })
                .background(TitleHold(keyboard: listKeyboard, isOnlySelection: { [chosen = $selection] id in
                    chosen.wrappedValue == [id]
                }) { id in
                    if let item = playlist.items.first(where: { $0.id == id }) { beginEdit(item) }
                })
                // The text box goes with its row: another playlist has no row for it.
                .onChange(of: library.selection) { _ in commitEdit() }
                // Nor has a video that was taken out of the list while its title was open
                // (removed from the menu, its file deleted): the box would stay as state with
                // no row, and Space and Return would go on being left to it.
                .onChange(of: playlist.items.count) { _ in
                    if let id = editingID, !playlist.items.contains(where: { $0.id == id }) { cancelEdit() }
                }
                .overlay {
                    if playlist.items.isEmpty {
                        EmptyStateView(title: "Drop Videos Here", systemImage: "film.stack",
                                       message: "Drag in files or folders, or click Open to choose a video from your Mac and play it. MKV, MP4, AVI, MOV and most other formats work.") {
                            HStack {
                                Button("Open…") { player.chooseAndOpen(into: playlist.id) }
                                Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
                            }
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
                    // Beside the playlist's name, the list they add to, rather than with the
                    // playback controls on the right. The folder is the Mac's picture for opening
                    // a file: it plays what is chosen. The plus only lists it.
                    ToolbarItem(placement: .navigation) {
                        Button { player.chooseAndOpen(into: playlist.id) } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open a video from your Mac and play it")
                    }
                    ToolbarItem(placement: .navigation) {
                        Button { library.presentOpenPanel(into: playlist.id) } label: {
                            Label("Add Videos", systemImage: "plus")
                        }
                        .help("Add videos or folders to this playlist without playing them")
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
                // Videos just added (dropped, chosen, opened): the first of them is selected
                // and brought into view, so a drop at the foot of a long list isn't a guess.
                .onChange(of: library.reveal) { reveal in
                    guard let id = reveal?.item,
                          library.selectedPlaylist?.items.contains(where: { $0.id == id }) == true else { return }
                    // Once the list has the new rows. Without animation: the list only selects a
                    // row it has laid out, and an animated scroll gets there too late for that.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .center)
                        selection = [id]
                    }
                    // Rows not yet laid out are taken to be shorter than they are, so the first
                    // scroll of a long list stops short; the second pass has measured the rows
                    // the first one passed. The last pass asks only for the row to be in view,
                    // which goes by where the row really is: centering the last row of a list
                    // already at its foot could leave it half cut off, a row's height short.
                    for (delay, anchor) in [(0.15, UnitPoint.center), (0.4, nil)] as [(Double, UnitPoint?)] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if selection == [id] { proxy.scrollTo(id, anchor: anchor) }
                        }
                    }
                }
            }
        } else {
            EmptyStateView(title: "No Playlist Selected", systemImage: "list.bullet.rectangle")
        }
    }

    // MARK: Naming a video

    /// The title as a text box, in the row of the video being named. Built here, in the view
    /// that holds its keyboard focus, the way the sidebar builds a playlist's.
    private var titleEditor: some View {
        TextField("Title", text: $draftTitle)
            .textFieldStyle(.roundedBorder)
            .focused($titleFocused)
            // Return and Esc end the typing, and the keyboard goes back to the list for the
            // arrow keys, Space and Return. (Clicking elsewhere ends it too, and the keyboard
            // then belongs to what was clicked.)
            .onSubmit { commitEdit(); listKeyboard.take() }
            .onExitCommand { cancelEdit(); listKeyboard.take() }
            .onChange(of: titleFocused) { focused in
                if focused { titleHadFocus = true } else if titleHadFocus { commitEdit() }
            }
            // The box is taller than the line of text it stands in for, and its text sits in
            // from its edge: the row keeps its height and the name stays about where it was.
            .padding(.vertical, -3)
            .padding(.leading, -5)
    }

    /// Turns a video's title into a text box holding its name, selected to type over: Rename
    /// in the right-click menu, a press held on the title, and a click on the title of the
    /// selected video (`TitlePress`).
    private func beginEdit(_ item: MediaItem) {
        commitEdit()   // a title still open keeps what was typed
        draftTitle = item.displayName
        titleHadFocus = false
        // From a box still open on another row this is still true, and setting it true again
        // would move nothing: the new box would open without the keyboard.
        titleFocused = false
        editingID = item.id
        DispatchQueue.main.async { titleFocused = true }
    }

    /// Return, or the keyboard going elsewhere: the video takes the name typed. Nothing typed
    /// gives it back the name made from its file.
    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        titleHadFocus = false
        guard let item = library.playlists.lazy.flatMap(\.items).first(where: { $0.id == id }) else { return }
        library.setName(draftTitle, for: item.url)
        player.nameChanged(for: item.url)
    }

    /// Esc: the name stays as it was.
    private func cancelEdit() {
        editingID = nil
        titleHadFocus = false
    }

    /// Locate…: asks where a missing video's file is now, starting in the folder it was in or
    /// the nearest one above it that still exists.
    private func locate(_ item: MediaItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Locate"
        panel.message = "Choose the file for “\(item.displayName)”. It was at \(item.url.path)."
        var folder = item.url.deletingLastPathComponent()
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.path) { folder.deleteLastPathComponent() }
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commitEdit()
        library.relocate(item, to: url)
    }

    /// Every video in the playlist: ⌘A, and Select All in the right-click menus.
    private func selectAll(in playlist: Playlist) {
        selection = Set(playlist.items.map(\.id))
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
            } else if Prefs.bool(Prefs.resumePlayback), let resume = library.resumePosition(for: item.url) {
                // Only with "resume where I left off" on: with it off the video starts at 0,
                // and the menu promised a place it wouldn't go to.
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
            Button("Details") {
                player.infoItem = item
                DetailsWindow.shared.show(item, player: player, library: library)
            }
            if items.count == 1 {
                Button("Rename") { beginEdit(item) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            // A file that was moved or renamed in the Finder: point the row at where it is now,
            // keeping its place, its watched mark, its subtitles and its name.
            if items.contains(where: { !$0.exists }) {
                if items.count == 1 {
                    Button("Locate…") { locate(item) }
                }
                Button("Remove Missing Videos") {
                    commitEdit()
                    let removed = library.removeMissing(from: playlist.id)
                    selection.subtract(removed.map(\.id))
                }
            }
            Divider()
            if items.contains(where: { library.watched.contains($0.url.path) || library.progress[$0.url.path] != nil }) {
                Button("Mark as Unwatched") { player.setWatched(false, for: items) }
            }
            if items.contains(where: { !library.watched.contains($0.url.path) }) {
                Button("Mark as Watched") { player.setWatched(true, for: items) }
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
            if items.count < playlist.items.count {
                Button("Select All") { selectAll(in: playlist) }
            }
            sortMenu(for: playlist)
            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
            Divider()
            Button("Remove from Playlist") { library.remove(ids, from: playlist.id) }
            Button(items.count == 1 ? "Delete File…" : "Delete \(items.count) Files…", role: .destructive) { filesToDelete = items }
        } else {
            Button("Open…") { player.chooseAndOpen(into: playlist.id) }
            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
            if !playlist.items.isEmpty {
                Button("Select All") { selectAll(in: playlist) }
            }
            sortMenu(for: playlist)
            Button("New Playlist") { library.newPlaylist() }
        }
    }

    /// Sort, in both right-click menus: puts the playlist in order once. Nothing to offer
    /// with fewer than two videos.
    @ViewBuilder
    private func sortMenu(for playlist: Playlist) -> some View {
        if playlist.items.count > 1 {
            Menu("Sort") {
                ForEach(PlaylistOrder.allCases, id: \.self) { order in
                    Button(order.label) {
                        commitEdit()
                        library.sort(playlist.id, by: order)
                    }
                }
            }
        }
    }
}

/// Space and Return on the playlist. `onKeyPress` is macOS 14's way; before it, a key monitor
/// that only acts while a list has the keyboard, so typing in a text field is left alone.
private struct ListKeys: ViewModifier {
    /// A video's title is being typed in the list: both keys are the text's.
    var isTyping = false
    let onSpace: () -> Void
    let onReturn: () -> Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.space) {
                    if isTyping { return .ignored }
                    onSpace()
                    return .handled
                }
                .onKeyPress(.return) { !isTyping && onReturn() ? .handled : .ignored }
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

/// ⌘A selects every video in the playlist wherever the keyboard is in the main window. The
/// system's Select All goes to whatever has the keyboard, and after a click in the sidebar
/// that is the list of playlists, which has nothing to select. While text is being typed (a
/// playlist's name, a title to search for) the key is left to the text.
private struct SelectAllKey: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.action = action }

    final class MonitorView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, !(self.window?.firstResponder is NSText),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "a" else { return event }
                self.action?()
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct MediaRow: View {
    let item: MediaItem
    let isCurrent: Bool
    /// The text box that stands in for the title while the video is being named.
    var titleEditor: AnyView? = nil
    @EnvironmentObject private var library: Library
    @State private var info: MediaInfo?
    @State private var poster: NSImage?
    @State private var details: MovieDetails?
    @State private var failed = false
    /// Whether the file is there, asked away from the main thread and kept: asked on every
    /// redraw of every row, a disk that had stopped answering froze the whole window.
    @State private var missing = false
    /// Counted up to look at the file again (Driftcast brought forward after the Finder).
    @State private var looks = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // Red when the file is gone (the user's request, 2026-11-22); gray for one
                    // that is there but can't be read.
                    Image(systemName: failed ? "exclamationmark.triangle" : "film")
                        .foregroundStyle(missing ? Color.red : Color.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
                    }
                    if let titleEditor {
                        titleEditor
                    } else {
                        TitleLine(item: item)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            // Where a press is held, or the selected video clicked, to name it (`TitleHold`).
                            .background(TitleMarker(id: item.id).allowsHitTesting(false))
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A file found again, or gone, while Driftcast was behind another app.
            let url = item.url, wasThere = !missing
            Task {
                let there = await Self.fileExists(url)
                if there != wasThere, url == item.url { looks += 1 }
            }
        }
        .task(id: RowKey(url: item.url, looks: looks)) {
            let there = await Self.fileExists(item.url)
            if Task.isCancelled { return }
            missing = !there
            failed = false
            guard there else { failed = true; return }
            do {
                let i = try await MediaProbe.shared.probe(item.url)
                info = i
                if let data = await Thumbnailer.shared.poster(for: item.url, duration: i.duration) {
                    poster = NSImage(data: data)
                }
            } catch {
                failed = true
            }
            // The year and an episode's name for the detail line; cached answers come back at once, new ones
            // are fetched no faster than the services allow.
            details = await MetadataLookup.shared.cached(for: item.url)
            if details == nil, MetadataLookup.isEnabled, !Task.isCancelled {
                details = await MetadataLookup.shared.details(for: item.url)
            }
        }
    }

    private struct RowKey: Hashable {
        let url: URL
        let looks: Int
    }

    private nonisolated static func fileExists(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: url.path) }.value
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
        if missing { return "File not found" }
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
            // The title line already says "S4 E7"; this line names the episode.
            if details.isEpisode, let name = details.episodeTitle { parts.append(name) }
            // When it came out: a film's year, the year an episode was first shown. Review
            // scores are in the details panel, with where each comes from.
            if let year = details.listYear { parts.append(String(year)) }
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

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: Library
    @State private var renamingID: Playlist.ID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        // A click on the empty space below the playlists would select none of them, and the
        // window then had no list at all: the playlist shown stays selected instead.
        List(selection: Binding(get: { library.selection }, set: { if let id = $0 { library.selection = id } })) {
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    row(for: playlist)
                        .tag(playlist.id)
                        .onDrop(of: Self.dropTypes, isTargeted: nil) { receive($0, onto: playlist.id) }
                }
                // Drag a playlist up or down to put the sidebar in another order.
                .onMove { library.movePlaylist(from: $0, to: $1) }
                // Dropped between or below the playlists: a new one where the line is drawn,
                // named after what was dropped ("The Sopranos S4"), for files from the Finder
                // and rows from the list alike (the user's request, 2026-11-20). As an insert,
                // because a drop handler on the whole list never hears of a row: a row's drag
                // also carries the list's own reorder marker (com.apple.SwiftUI.listReorder),
                // so the sidebar's table takes the drag for itself and turns it down unless
                // told it may be inserted. And once the table inserts one type it turns down
                // the others, files included, so both are named here.
                .onInsert(of: Self.dropTypes) { place, providers in
                    _ = receive(providers, onto: nil, at: place)
                }
            }
        }
        // Wherever the table itself doesn't take the drop.
        .onDrop(of: Self.dropTypes, isTargeted: nil) { receive($0, onto: nil) }
        // On the list rather than on each row, so a right-click anywhere on a playlist's row
        // opens it, not only on its name, and one in the empty space below the playlists
        // offers New Playlist (the user asked for New and Delete there, 2026-11-19).
        .contextMenu(forSelectionType: Playlist.ID.self) { ids in
            menu(for: library.playlists.first { ids.contains($0.id) })
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { newPlaylist() } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    private static let dropTypes = [DraggedVideo.type, .fileURL]

    /// Rows from the list are moved (with Option held, listed here as well); files are added.
    /// Onto a playlist they go into it; anywhere else they get a playlist of their own.
    private func receive(_ providers: [NSItemProvider], onto target: Playlist.ID?, at place: Int? = nil) -> Bool {
        let copying = NSEvent.modifierFlags.contains(.option)
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(DraggedVideo.typeIdentifier) }) {
            let noted = DraggedVideo.takePending()
            if !noted.isEmpty {
                take(noted, onto: target, copying: copying, at: place)
                return true
            }
            DraggedVideo.load(from: providers) { rows in
                MainActor.assumeIsolated { take(rows, onto: target, copying: copying, at: place) }
            }
            return true
        }
        guard providers.contains(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        DraggedVideo.loadFiles(from: providers) { urls in
            MainActor.assumeIsolated {
                if let target { library.add(urls, to: target) } else {
                    let before = Set(library.playlists.map(\.id))
                    library.addToNewPlaylist(urls)
                    library.settle(newSince: before, at: place)
                }
            }
        }
        return true
    }

    private func take(_ rows: [DraggedVideo], onto target: Playlist.ID?, copying: Bool, at place: Int? = nil) {
        for (source, group) in Dictionary(grouping: rows, by: \.playlist) {
            let ids = Set(group.map(\.item))
            let urls = library.playlists.first { $0.id == source }?.items.filter { ids.contains($0.id) }.map(\.url) ?? []
            switch (target, copying) {
            case (let target?, false): library.moveItems(ids, from: source, to: target)
            case (let target?, true): library.add(urls, to: target)
            case (nil, false): library.moveToNewPlaylist(ids, from: source, at: place)
            case (nil, true): library.addToNewPlaylist(urls)
            }
        }
    }

    /// The right-click menu: New Playlist and Delete Playlist first, then the clicked
    /// playlist's own commands. In the empty space there is no playlist, so only New.
    @ViewBuilder
    private func menu(for playlist: Playlist?) -> some View {
        Button("New Playlist") { newPlaylist() }
        if let playlist {
            Button("Delete Playlist", role: .destructive) { library.deletePlaylist(playlist.id) }
                .disabled(library.playlists.count < 2)
            Divider()
            Button("Rename") { beginRename(playlist) }
            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
        }
    }

    /// A new playlist, selected, with its name ready to type over.
    private func newPlaylist() {
        let id = library.newPlaylist()
        if let p = library.playlists.first(where: { $0.id == id }) { beginRename(p) }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        if renamingID == playlist.id {
            TextField("Playlist name", text: $draftName)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { focused in if !focused { commitRename() } }
        } else {
            Label(playlist.name, systemImage: "list.bullet.rectangle")
                .badge(playlist.items.count)
        }
    }

    private func beginRename(_ playlist: Playlist) {
        draftName = playlist.name
        renamingID = playlist.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let id = renamingID { library.rename(id, to: draftName) }
        renamingID = nil
    }
}

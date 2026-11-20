import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: Library
    @State private var renamingID: Playlist.ID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $library.selection) {
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    row(for: playlist)
                        .tag(playlist.id)
                        .dropDestination(for: URL.self) { urls, _ in
                            !library.add(urls, to: playlist.id).isEmpty
                        }
                }
            }
        }
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

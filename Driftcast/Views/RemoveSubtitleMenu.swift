import SwiftUI

/// "Remove Subtitle", with the subtitle files attached to a video: the way to take one off
/// that isn't in sync. Shown only when the video has such files; tracks inside the video and
/// files beside it can't be removed here and aren't listed.
struct RemoveSubtitleMenu: View {
    /// The video; nil means the one playing.
    var item: MediaItem? = nil
    // The player alone: the video window is given no library, and asking for one there would
    // crash. Attaching and removing a file both change what the player publishes.
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        let files = player.removableSubtitles(for: item)
        if !files.isEmpty {
            Menu("Remove Subtitle") {
                ForEach(files, id: \.self) { file in
                    Button(SubtitleChoice.external(file).label) { player.removeSubtitleFile(file, from: item) }
                }
            }
        }
    }
}

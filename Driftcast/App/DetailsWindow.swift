import AppKit
import SwiftUI

/// The Details window: everything known about one video in a small window of its own. Poster,
/// plot, people, ratings, the episode, what is in the file and how it would be sent, and its
/// closed captions: the details panel's contents (`DetailsView`), held to the video the window
/// was opened for instead of following the selection.
///
/// Details in the right-click menu and the File menu used to open the panel beside the
/// playlist. With the panel already open on that video the command changed nothing, and looked
/// broken (the user's report, 2026-11-20). A window always answers.
///
/// One window: Details on another video shows that one in it. An AppKit window rather than a
/// SwiftUI scene, like About, so that it is never reopened by itself at launch.
@MainActor
final class DetailsWindow {
    static let shared = DetailsWindow()

    /// The video the window is about, for its view to follow when another is asked for.
    final class Shown: ObservableObject {
        @Published var item: MediaItem?
    }

    private let shown = Shown()
    private var window: NSWindow?

    func show(_ item: MediaItem, player: PlaybackController, library: Library) {
        shown.item = item
        if window == nil {
            let root = DetailsWindowContent(shown: shown)
                .environmentObject(player)
                .environmentObject(library)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []   // the window's size is the person's to change
            // A panel, so that Esc closes it as it closes any small window of facts.
            let window = NSPanel(contentViewController: host)
            window.styleMask = [.titled, .closable, .resizable]
            window.hidesOnDeactivate = false
            window.isFloatingPanel = false
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 340, height: 400)
            // Small, the width the details were laid out for, and never taller than the screen.
            let room = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 380, height: min(720, room - 80)))
            window.center()
            window.setFrameAutosaveName("DetailsWindow")   // it comes back where it was left
            self.window = window
        }
        window?.title = item.displayName
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DetailsWindowContent: View {
    @ObservedObject var shown: DetailsWindow.Shown

    var body: some View {
        if let item = shown.item {
            DetailsView(pinned: item)
                .id(item.url)   // another video starts from nothing, not from the last one's details
        }
    }
}

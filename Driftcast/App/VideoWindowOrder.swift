import AppKit

/// Keeps the Video window in front of the main window, and moving with it.
///
/// macOS brings forward only the window that was clicked. With a video playing, a click on the
/// main window (to pick the next video, say) put it over the Video window; and with Driftcast
/// behind another app, a click on the main window brought that one back and left the video
/// where it was, behind the other app. Either way the player was lost (the user's report,
/// 2026-11-20).
///
/// At first the Video window was put back above the main one whenever the main one came
/// forward. That missed a click on the main window while it already had the keyboard: macOS
/// raises it then without saying so, and the video went behind (the user's report the same
/// night: "this little window should always be attached to the main window"). So every press
/// in the main window now puts the Video window back above it, and the Video window moves by
/// as much as the main one does.
///
/// Not a child window: macOS keeps a child above its parent and carries it along, but won't
/// let it go full screen by itself (tried, 2026-11-20: the green button did nothing), and a
/// video player has to. Nor raised a level: a floating window would sit over every other
/// app as well. The keyboard stays with the window that had it, so the list's keys go on
/// working.
@MainActor
enum VideoWindowOrder {
    /// Where the main window was last, to move the Video window by as much as it moved.
    private static var lastMainFrame: NSRect?

    static func install() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow,
                      window.identifier?.rawValue.hasPrefix("main") == true else { return }
                MainActor.assumeIsolated { settle() }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { settle() }
        }
        // Any press in the main window, the one macOS raises without a word included, and its
        // release: the list delays raising its window until mouse-up (a press there may
        // start a drag), so the Video window is put back after that as well.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                    .leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
            if event.window?.identifier?.rawValue.hasPrefix("main") == true {
                MainActor.assumeIsolated { settle() }
            }
            return event
        }
        center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            MainActor.assumeIsolated { follow(window) }
        }
        center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            MainActor.assumeIsolated { lastMainFrame = window.frame }
        }
        // Posted when a drag of the window by its title bar begins, and not when the app
        // moves it: the mark of a place the person chose. A Video window carried along by
        // the main one is not one: the pointer is on the main window then.
        center.addObserver(forName: NSWindow.willMoveNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue.hasPrefix("video") == true,
                  window.frame.contains(NSEvent.mouseLocation) else { return }
            UserDefaults.standard.set(true, forKey: placedByHandKey)
        }
    }

    /// Now, and once more when macOS has finished bringing the clicked window forward: it
    /// goes on ordering windows after the one clicked has been told it has the keyboard, and
    /// a press in the list is only over at mouse-up.
    private static func settle() {
        raise()
        DispatchQueue.main.async { MainActor.assumeIsolated { raise() } }
        // The list raises its window a moment after mouse-up, later than the line above runs
        // (seen 2026-11-20: the main window ended on top after every click in the list).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { MainActor.assumeIsolated { raise() } }
    }

    /// Whether the Video window is one to move: on screen beside the main window. Not one in
    /// the Dock, in full screen or on another desktop, which are where the person put them.
    static func shouldRaise(videoVisible: Bool, videoMinimized: Bool, videoFullScreen: Bool,
                            mainVisible: Bool, mainFullScreen: Bool, sameDesktop: Bool) -> Bool {
        videoVisible && !videoMinimized && !videoFullScreen && mainVisible && !mainFullScreen && sameDesktop
    }

    private static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    private static func videoToMove() -> (main: NSWindow, video: NSWindow)? {
        guard let main = window("main"), let video = window("video"),
              shouldRaise(videoVisible: video.isVisible, videoMinimized: video.isMiniaturized,
                          videoFullScreen: video.styleMask.contains(.fullScreen),
                          mainVisible: main.isVisible, mainFullScreen: main.styleMask.contains(.fullScreen),
                          sameDesktop: video.isOnActiveSpace && main.isOnActiveSpace) else { return nil }
        return (main, video)
    }

    static func raise() {
        guard let (main, video) = videoToMove() else { return }
        video.order(.above, relativeTo: main.windowNumber)
        if lastMainFrame == nil { lastMainFrame = main.frame }
    }

    /// The main window moved (not resized): the Video window goes the same way by as much.
    private static func follow(_ main: NSWindow) {
        defer { lastMainFrame = main.frame }
        guard let last = lastMainFrame, last.size == main.frame.size, let (_, video) = videoToMove() else { return }
        let dx = main.frame.minX - last.minX, dy = main.frame.minY - last.minY
        guard dx != 0 || dy != 0 else { return }
        video.setFrameOrigin(NSPoint(x: video.frame.minX + dx, y: video.frame.minY + dy))
    }

    // MARK: Where the window opens

    /// Set once the person has dragged the Video window somewhere. From then on it opens
    /// where they left it (macOS keeps a window's place) and is not put beside the main one.
    static let placedByHandKey = "videoWindowPlacedByHand"

    /// A Video window that has just opened is put beside the main window. Always in front as
    /// it now is, a Video window opened over the main one hid the list of videos behind the
    /// picture (the user's report, 2026-11-20, and their choice: in front, opened beside).
    /// Left where it is once the person has placed it themselves, and when either window is
    /// in full screen or the main one is out of sight.
    static func placeBeside() {
        guard !UserDefaults.standard.bool(forKey: placedByHandKey),
              let main = window("main"), let video = window("video"),
              main.isVisible, !main.isMiniaturized, main.isOnActiveSpace,
              !main.styleMask.contains(.fullScreen), !video.styleMask.contains(.fullScreen),
              let screen = (main.screen ?? video.screen)?.visibleFrame else { return }
        // The smallest frame the window can have: what its content needs, title bar included.
        let least = video.frameRect(forContentRect: NSRect(origin: .zero, size: video.contentMinSize)).size
        let minimum = NSSize(width: max(least.width, 480), height: max(least.height, 270))
        let frame = VideoWindowGeometry.place(size: video.frame.size, minimum: minimum, beside: main.frame, on: screen)
        if frame != video.frame { video.setFrame(frame, display: true) }
    }
}

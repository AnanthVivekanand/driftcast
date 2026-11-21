import AppKit
import os
import SwiftUI

/// Marks where a video's title is drawn in its row, for `TitleHold` to find.
struct TitleMarker: NSViewRepresentable {
    let id: MediaItem.ID

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.itemID = id
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) { view.itemID = id }

    final class MarkerView: NSView {
        var itemID: MediaItem.ID?
        /// Never what a click lands on: the row behind it is.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The video whose title is drawn at a point of the window, if one is.
    static func id(at point: NSPoint, in window: NSWindow) -> MediaItem.ID? {
        window.contentView.flatMap { find(in: $0, at: point) }
    }

    private static func find(in view: NSView, at point: NSPoint) -> MediaItem.ID? {
        if let marker = view as? MarkerView, let id = marker.itemID, !marker.isHiddenOrHasHiddenAncestor {
            // The part in sight: a row scrolled half under the toolbar has a title only below
            // it. Cut to the marker itself, because a view that doesn't clip what it draws (the
            // rule since macOS 14) reports as visible everything its row shows, and a press
            // anywhere in the row would count as one on the title.
            let seen = marker.visibleRect.intersection(marker.bounds)
            if !seen.isEmpty, marker.convert(seen, to: nil).contains(point) { return id }
        }
        for sub in view.subviews {
            if let id = find(in: sub, at: point) { return id }
        }
        return nil
    }
}

/// Notices the two things that turn a video's title into a text box (`TitlePress`): the mouse
/// button held down on it, and a click on the title of the one selected video with nothing
/// after it, as in the Finder (the user asked for both, 2026-11-20).
///
/// Not a gesture on the title: that would take the click, and a click on a title has to go on
/// selecting the row, a double-click playing it and a drag moving it. The mouse-down is only
/// watched, and passed on as it came. Nor can the release be watched: the list tracks the mouse
/// in a loop of its own until the button comes up, and no monitor sees those events. So when
/// each wait is up the mouse itself is asked: down or up, and where?
struct TitleHold: NSViewRepresentable {
    /// The mouse as it is this instant: which buttons are down, and where on the screen.
    /// Asked, not followed through events (see above). A variable so a test can stand in for it.
    static var mouse: () -> (buttons: Int, at: NSPoint) = { (NSEvent.pressedMouseButtons, NSEvent.mouseLocation) }
    /// One line per step of a press on a title, to read back what a hand really did when the
    /// box doesn't open for someone: `log show --predicate 'category == "rename"'`.
    fileprivate static let log = Logger(subsystem: "com.leechsoftware.driftcast", category: "rename")

    /// How the playlist gives its list the keyboard back when a title's text box closes.
    var keyboard: ListKeyboard? = nil
    /// Whether a video is the one selected row. Asked as a press lands, before the list has
    /// acted on it, and again when the wait after a click is up.
    var isOnlySelection: (MediaItem.ID) -> Bool = { _ in false }
    let onHold: (MediaItem.ID) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onHold = onHold
        view.isOnlySelection = isOnlySelection
        keyboard?.view = view
    }

    final class MonitorView: NSView {
        var onHold: ((MediaItem.ID) -> Void)?
        var isOnlySelection: ((MediaItem.ID) -> Bool)?
        private var monitor: Any?
        private var pressed: (id: MediaItem.ID, at: NSPoint, selected: Bool)?
        /// The selected video whose title was clicked, while it is seen that nothing follows.
        private var clicked: MediaItem.ID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            forget()
            guard window != nil else { return }
            // A key or another button meanwhile calls off whatever was waiting: the click was
            // the start of something else (Space to play, the arrow keys, a right-click).
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                if event.type == .leftMouseDown { self?.mouseWentDown(event) } else { self?.forget() }
                return event
            }
        }

        private func mouseWentDown(_ event: NSEvent) {
            // Every press starts the wait again, so an earlier one can't come due during this one.
            forget()
            // A double-click plays; with Shift or Command the click is choosing rows; with
            // Control it is a right-click.
            // Not under a sheet, and not in the toolbar, which rows scrolled out of sight lie under.
            guard let window, event.window === window, event.clickCount == 1,
                  window.attachedSheet == nil, event.locationInWindow.y <= window.contentLayoutRect.maxY,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
                  let id = TitleMarker.id(at: event.locationInWindow, in: window) else { return }
            // The list ends a press by taking the keyboard if it didn't have it when the press
            // began (`-[NSTableView mouseDown:]`, seen in a recording of who moved the keyboard).
            // That took it from the text box this very press had opened, and a text box that
            // loses the keyboard closes: the title turned into a box and back as the button
            // came up (the user's report, 2026-11-20: "a long click on a title doesn't enter it
            // into edit mode"). It only worked when the list happened to have the keyboard
            // already. So the list is given it now, before the press reaches it.
            // The Finder's rule for a click: only on the name of what is already selected, in
            // the window already in use. A click that brings the window forward does only that.
            let selected = window.isKeyWindow && NSApp.isActive && isOnlySelection?(id) == true
            if let table = table(), window.firstResponder !== table { window.makeFirstResponder(table) }
            pressed = (id, TitleHold.mouse().at, selected)
            TitleHold.log.notice("press on a title, its video the one selected: \(selected)")
            // In the common modes, to come due while the list is tracking the mouse.
            perform(#selector(timeIsUp), with: nil, afterDelay: TitlePress.holdSeconds, inModes: [.common])
        }

        @objc private func timeIsUp() {
            guard let press = pressed else { return }
            pressed = nil
            let now = TitleHold.mouse()
            let down = now.buttons & 1 == 1
            let moved = hypot(now.at.x - press.at.x, now.at.y - press.at.y)
            let outcome = TitlePress.afterHold(buttonDown: down, moved: moved, wasOnlySelection: press.selected)
            TitleHold.log.notice("after \(TitlePress.holdSeconds) s: button \(down ? "down" : "up", privacy: .public), moved \(moved, format: .fixed(precision: 1)) points: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .edit:
                onHold?(press.id)
            case .wait:
                clicked = press.id
                let more = TitlePress.pause(doubleClick: NSEvent.doubleClickInterval) - TitlePress.holdSeconds
                perform(#selector(pauseIsUp), with: nil, afterDelay: max(0, more), inModes: [.common])
            case .nothing:
                break
            }
        }

        /// Nothing followed the click (a second click, a key or another button would have
        /// called this off). The box opens if the pointer is still on that title, in the
        /// window still in use, and the video is still the one selected.
        @objc private func pauseIsUp() {
            guard let id = clicked else { return }
            clicked = nil
            let now = TitleHold.mouse()
            guard let window else { return }
            let up = now.buttons & 1 == 0
            let inUse = window.isKeyWindow && NSApp.isActive && window.attachedSheet == nil
            let selected = isOnlySelection?(id) == true
            let onTitle = TitleMarker.id(at: window.convertPoint(fromScreen: now.at), in: window) == id
            TitleHold.log.notice("after the click: button up \(up), window in use \(inUse), still the one selected \(selected), pointer on the title \(onTitle)")
            if up, inUse, selected, onTitle { onHold?(id) }
        }

        private func forget() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeIsUp), object: nil)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(pauseIsUp), object: nil)
            pressed = nil
            clicked = nil
        }

        /// The list this view lies behind: the table whose middle is on this view's ground.
        /// (The sidebar is a table too, and it is beside this view, not over it.)
        func table() -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            let ground = convert(bounds, to: nil)
            var found: NSTableView?
            func look(_ view: NSView) {
                guard found == nil, !view.isHidden else { return }
                if let table = view as? NSTableView {
                    let seen = (table.enclosingScrollView ?? table)
                    let frame = seen.convert(seen.bounds, to: nil)
                    if ground.contains(NSPoint(x: frame.midX, y: frame.midY)) { found = table }
                    return
                }
                view.subviews.forEach(look)
            }
            look(content)
            return found
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Gives the playlist's list the keyboard. When a title's text box closes on Return or Esc the
/// keyboard is left with the window, and the arrow keys, Space and Return do nothing until a
/// row is clicked; the playlist calls `take()` then. It reaches the list through the view
/// `TitleHold` puts behind it.
@MainActor
final class ListKeyboard {
    fileprivate weak var view: TitleHold.MonitorView?

    func take() {
        guard let view, let window = view.window, let table = view.table() else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }
}

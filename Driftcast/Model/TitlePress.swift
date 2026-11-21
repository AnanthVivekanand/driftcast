import CoreGraphics
import Foundation

/// What a press on a video's title in the list turns out to be. Two things turn the title into
/// a text box:
///
/// - the button held down on it, and
/// - a click on the title of the video that is already the one selected, with nothing after
///   it: the Finder's way of renaming a file. (The user tried exactly that, 2026-11-20:
///   "clicking on a title and waiting a sec doesn't let you edit the title".)
///
/// A click on any other title only selects its row, as it does in the Finder. Otherwise a
/// text box would open under the pointer every time a row was clicked to read its details.
///
/// Each is decided from what the mouse is doing when a wait is up, because the list lets
/// nothing watch a press as it goes (see `TitleHold`).
enum TitlePress {
    /// How long the button is held. Longer than any click, short enough not to feel stuck.
    static let holdSeconds: TimeInterval = 0.6
    /// How far the pointer may wander while the button is held; further is the start of a drag.
    static let slack: CGFloat = 4

    enum Outcome: Equatable {
        /// The title turns into a text box now.
        case edit
        /// A click on the selected video's title: the box opens if nothing follows (`pause`).
        case wait
        case nothing
    }

    /// `holdSeconds` after the button went down: still down and still, it is a held press;
    /// down and moved, a drag; up again, a click.
    static func afterHold(buttonDown: Bool, moved: CGFloat, wasOnlySelection: Bool) -> Outcome {
        if buttonDown { return moved <= slack ? .edit : .nothing }
        return wasOnlySelection ? .wait : .nothing
    }

    /// How long after the button went down a click counts as followed by nothing: past the
    /// time in which a second click would make it a double-click, which plays the video.
    static func pause(doubleClick: TimeInterval) -> TimeInterval {
        max(doubleClick, holdSeconds) + 0.3
    }
}

import CoreGraphics
import Foundation

// Harness checks for playback and windows: the controller, the queue, menus.
// Uses check(_:_:), spin, await_ and fetch from Helpers.swift, and the global mediaDir (the
// test media folder, from the command line) that harness.swift defines.
@MainActor func playbackTests() {
    videoWindowTests()
    titlePressTests()
}

// What turns a title in the list into a text box: the button held on it, or a click on the
// title of the one selected video with nothing after it.
private func titlePressTests() {
    typealias P = TitlePress
    check(P.afterHold(buttonDown: true, moved: 0, wasOnlySelection: false) == .edit,
          "title press: the button held still on any title opens the text box")
    check(P.afterHold(buttonDown: true, moved: 3.5, wasOnlySelection: false) == .edit,
          "title press: a hand's small movement while holding still counts as held")
    check(P.afterHold(buttonDown: true, moved: 9, wasOnlySelection: true) == .nothing,
          "title press: the button down and the pointer moved is a drag, not a rename")
    check(P.afterHold(buttonDown: false, moved: 0, wasOnlySelection: true) == .wait,
          "title press: a click on the selected video's title waits to see that nothing follows")
    check(P.afterHold(buttonDown: false, moved: 7, wasOnlySelection: true) == .wait,
          "title press: the pointer may move along the title after a click")
    check(P.afterHold(buttonDown: false, moved: 0, wasOnlySelection: false) == .nothing,
          "title press: a click on a title that wasn't selected only selects its row")
    check(P.pause(doubleClick: 0.5) > 0.5 && P.pause(doubleClick: 0.5) <= 1.0,
          "title press: the box opens within a second of the click, after a double-click could still come (\(P.pause(doubleClick: 0.5)) s)")
    check(P.pause(doubleClick: 2) > 2,
          "title press: a slow double-click setting is waited out (\(P.pause(doubleClick: 2)) s)")
    check(P.pause(doubleClick: 0.1) > P.holdSeconds,
          "title press: never before the held press has been ruled out (\(P.pause(doubleClick: 0.1)) s)")
}

// Where the Video window opens, and the size that fits its picture.
private func videoWindowTests() {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let video = CGSize(width: 960, height: 568), least = CGSize(width: 480, height: 298)
    func place(_ main: CGRect, on s: CGRect = screen, size: CGSize = video) -> CGRect {
        VideoWindowGeometry.place(size: size, minimum: least, beside: main, on: s)
    }
    let roomy = CGRect(x: 100, y: 500, width: 980, height: 670)
    let right = place(roomy)
    check(right == CGRect(x: 1092, y: 602, width: 960, height: 568),
          "video window: opens to the right of the main window, tops in line, at its own size (\(right))")
    let atRightEdge = CGRect(x: 1500, y: 500, width: 980, height: 670)
    let left = place(atRightEdge)
    check(left == CGRect(x: 528, y: 602, width: 960, height: 568),
          "video window: with no room on the right it opens on the left (\(left))")
    // The user's own arrangement on 2026-11-20: 778 points free each side of the main window.
    let centered = CGRect(x: 790, y: 429, width: 980, height: 670)
    let smaller = place(centered)
    check(smaller.minX == 1782 && smaller.width == 778 && smaller.height == 460 && smaller.maxY == centered.maxY
          && !smaller.intersects(centered) && screen.contains(smaller),
          "video window: where no side has room for all of it, it is made smaller for the first side with the most, keeping its shape (\(smaller))")
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let wide = CGRect(x: 0, y: 400, width: 1440, height: 475)
    let below = place(wide, on: laptop)
    check(below.maxY == 388 && below.minX == 0 && below.height == 388 && !below.intersects(wide) && laptop.contains(below),
          "video window: under a main window as wide as the screen, in the room below it (\(below))")
    let low = CGRect(x: 0, y: 0, width: 1440, height: 475)
    let above = place(low, on: laptop)
    check(above.minY == 487 && !above.intersects(low) && laptop.contains(above),
          "video window: above a main window at the foot of the screen (\(above))")
    let full = place(screen)
    check(full == CGRect(x: 2040, y: 96, width: 504, height: 298),
          "video window: over a main window that fills the screen, at its smallest in the lower right, clear of the playback bar (\(full))")
    let hanging = CGRect(x: -400, y: -200, width: 980, height: 670)
    let kept = place(hanging)
    check(screen.contains(kept) && !kept.intersects(hanging),
          "video window: beside a main window that hangs off the screen it still opens on the screen (\(kept))")
    for main in [roomy, atRightEdge, centered] {
        let spot = place(main)
        check(spot == place(main, size: spot.size) || place(main, size: spot.size).size == spot.size,
              "video window: placing it twice leaves it where the first put it (\(spot))")
    }

    let none = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let pictureLeast = CGSize(width: 480, height: 270)
    func room(_ shape: CGFloat, _ width: CGFloat, bar: CGFloat = 0, most: CGSize = none) -> CGSize {
        VideoWindowGeometry.room(forShape: shape, width: width, bar: bar, minimum: pictureLeast, most: most)
    }
    check(room(16.0 / 9, 960) == CGSize(width: 960, height: 540) && room(16.0 / 9, 960, bar: 29) == CGSize(width: 960, height: 569),
          "picture fit: a 16:9 video 960 wide gets 540 of height, and the bar's height on top of that")
    check(room(4.0 / 3, 960) == CGSize(width: 960, height: 720) && room(2.39, 960).height == 402,
          "picture fit: the height follows the video's own shape (4:3 \(room(4.0 / 3, 960)), 2.39:1 \(room(2.39, 960)))")
    let scope = room(2.39, 480)
    check(scope == CGSize(width: 645, height: 270),
          "picture fit: a wide film at the smallest width gets a wider window, not bars (\(scope))")
    let portrait = room(9.0 / 16, 960, most: CGSize(width: 2000, height: 1300))
    check(portrait == CGSize(width: 731, height: 1300),
          "picture fit: a tall video stops at the screen and gives up width to keep its shape (\(portrait))")
    let tight = room(16.0 / 9, 1200, bar: 29, most: CGSize(width: 800, height: 2000))
    check(tight == CGSize(width: 800, height: 479), "picture fit: no wider than the screen has room for (\(tight))")
    let cramped = room(16.0 / 9, 480, most: CGSize(width: 300, height: 200))
    check(cramped == CGSize(width: 480, height: 270), "picture fit: never under the smallest picture (\(cramped))")
    check(room(0, 700, bar: 20) == CGSize(width: 700, height: 290) && room(.nan, 700).width == 700,
          "picture fit: a shape that isn't one leaves the width alone")
}

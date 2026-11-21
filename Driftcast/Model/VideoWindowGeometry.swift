import CoreGraphics
import Foundation

/// The arithmetic of the Video window: where it opens, and the size that fits its picture.
/// Apart from the windows themselves so that it can be checked with numbers alone.
enum VideoWindowGeometry {
    /// Where a Video window of `size` opens so that the main window stays in view: beside it
    /// on the right, else on the left, else below, else above, its top (or left) edge in line
    /// with the main window's. Where no side has room for it as it is, it is made smaller,
    /// keeping its shape and not under `minimum`, for the side that leaves it largest. With no
    /// room on any side even so (a main window that fills the screen), it goes over the main
    /// window's lower right corner at its smallest, clear of the playback bar.
    /// Rectangles are the screen's, y upwards; `screen` is the part free of menu bar and Dock.
    static func place(size: CGSize, minimum: CGSize, beside main: CGRect, on screen: CGRect,
                      gap: CGFloat = 12) -> CGRect {
        enum Side: CaseIterable { case right, left, below, above }
        func room(_ side: Side) -> CGSize {
            switch side {
            case .right: return CGSize(width: screen.maxX - main.maxX - gap, height: screen.height)
            case .left: return CGSize(width: main.minX - gap - screen.minX, height: screen.height)
            case .below: return CGSize(width: screen.width, height: main.minY - gap - screen.minY)
            case .above: return CGSize(width: screen.width, height: screen.maxY - main.maxY - gap)
            }
        }
        guard size.width > 0, size.height > 0 else { return CGRect(origin: main.origin, size: size) }
        var best: (side: Side, scale: CGFloat)?
        for side in Side.allCases {
            let free = room(side)
            guard free.width > 0, free.height > 0 else { continue }
            let scale = min(1, free.width / size.width, free.height / size.height)
            guard size.width * scale >= minimum.width - 0.5, size.height * scale >= minimum.height - 0.5 else { continue }
            // The first side with room for all of it; failing that, the one with the most.
            if scale > (best?.scale ?? 0) + 0.001 { best = (side, scale) }
            if scale >= 1 { break }
        }
        func onScreen(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.origin.x = max(screen.minX, min(rect.minX, screen.maxX - rect.width))
            rect.origin.y = max(screen.minY, min(rect.minY, screen.maxY - rect.height))
            return rect
        }
        guard let best else {
            // No side has the room. As small as it goes, in the corner that covers least: the
            // end of the list, above the playback bar (about 80 points high).
            let scale = min(1, max(minimum.width / size.width, minimum.height / size.height))
            let small = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            return onScreen(CGRect(x: main.maxX - 16 - small.width, y: main.minY + 96, width: small.width, height: small.height))
        }
        let fitted = CGSize(width: (size.width * best.scale).rounded(.down), height: (size.height * best.scale).rounded(.down))
        let origin: CGPoint
        switch best.side {
        case .right: origin = CGPoint(x: main.maxX + gap, y: main.maxY - fitted.height)
        case .left: origin = CGPoint(x: main.minX - gap - fitted.width, y: main.maxY - fitted.height)
        case .below: origin = CGPoint(x: main.minX, y: main.minY - gap - fitted.height)
        case .above: origin = CGPoint(x: main.minX, y: main.maxY + gap)
        }
        // A main window that hangs off the screen's edge would take the Video window with it.
        return onScreen(CGRect(origin: origin, size: fitted))
    }

    /// The room below the title bar that shows a picture of `shape` (its width over its
    /// height) with nothing beside it, in a window `width` wide with a bar `bar` high under
    /// the picture. Never under the picture's `minimum`; a film too wide for the smallest
    /// picture gets a wider window instead. Kept within `most` where the minimum allows, the
    /// shape held by giving up width.
    static func room(forShape shape: CGFloat, width: CGFloat, bar: CGFloat, minimum: CGSize, most: CGSize) -> CGSize {
        guard shape.isFinite, shape > 0, width.isFinite else {
            return CGSize(width: max(width.isFinite ? width : 0, minimum.width), height: minimum.height + bar)
        }
        var w = max(width, minimum.width)
        var h = w / shape
        if h < minimum.height { h = minimum.height; w = h * shape }
        if w > most.width, most.width >= minimum.width, most.width / shape >= minimum.height {
            w = most.width; h = w / shape
        }
        if h + bar > most.height, most.height - bar >= minimum.height, (most.height - bar) * shape >= minimum.width {
            h = most.height - bar; w = h * shape
        }
        return CGSize(width: w.rounded(), height: h.rounded() + bar)
    }
}

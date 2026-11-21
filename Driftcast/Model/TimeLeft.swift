import Foundation

/// The line in the casting window's corner: where the video is, and how long until its end
/// credits. "14:08" and "22m, 14s left".
///
/// The time left stops at the credits, not at the end of the file, since the credits are not
/// what anyone is waiting for. Where they start is `WatchProgress.creditsPoint`: the file's
/// credits chapter when it has one, else an estimate. It is the point where the video also
/// counts as finished in the list. Past it, what is left of the file is given instead.
struct TimeLeft: Equatable {
    /// Where the video is: "14:08", "1:14:08".
    let stamp: String
    /// "22m, 14s left", or in the credits "2m, 5s to the end". Nil until the video's
    /// length is known.
    let left: String?

    init(position: Double, duration: Double, creditsStart: Double? = nil) {
        let at = position.isFinite ? max(0, position.rounded(.down)) : 0
        stamp = formatTime(at)
        guard duration.isFinite, duration > 0 else { left = nil; return }
        // Whole seconds on both sides, so the two numbers always tick together.
        let credits = WatchProgress.creditsPoint(duration: duration, creditsStart: creditsStart).rounded()
        if at < credits {
            left = Self.spelled(credits - at) + " left"
        } else {
            left = Self.spelled(max(0, duration.rounded() - at)) + " to the end"
        }
    }

    /// "22m, 14s", "1h, 5m, 9s", "48s". Commas, not "and" (the user's wording, 2026-11-20).
    static func spelled(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        if h > 0 { return "\(h)h, \(m)m, \(s)s" }
        if m > 0 { return "\(m)m, \(s)s" }
        return "\(s)s"
    }
}

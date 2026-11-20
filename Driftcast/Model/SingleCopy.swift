import AppKit

/// Driftcast runs as one copy at a time.
///
/// macOS opens a video with the newest copy of an app it knows of, whatever folder that copy
/// is in, even while another copy is already running: one in Applications and one in
/// Downloads, or one still on the disk image it came on. Each running copy keeps the
/// playlists in memory and writes the whole list back when something changes. With two open,
/// each save erases what the other had added, and the videos just dropped into one window
/// are missing from the other and gone at the next launch.
///
/// So the copy being opened takes over. It asks the one already running to quit, which makes
/// that one save its playlists and the place in what it was playing, waits for it to go, and
/// only then reads the playlists. Whatever was double-clicked opens here as usual.
enum SingleCopy {
    /// `-AllowSecondCopy YES` on the command line lets a copy start beside another, for a test
    /// run that keeps its data in a folder of its own.
    static var isAllowedBeside: Bool { UserDefaults.standard.bool(forKey: "AllowSecondCopy") }

    /// How long a running copy is given to save and quit.
    static let patience: TimeInterval = 6

    /// Which running copies this one replaces: those that were open before it. One that
    /// started later is the newcomer and replaces this one, and two that start in the same
    /// moment must not each close the other.
    static func replaced(_ others: [(pid: Int32, launched: Date?)], by mine: Date) -> [Int32] {
        others.filter { ($0.launched ?? .distantPast) < mine }.map(\.pid)
    }

    /// First thing at launch, before the playlists are read. True when this copy has them to
    /// itself. False when a running copy stayed open (it has a question on screen, say):
    /// that one has been brought forward, and this copy should quit without touching anything.
    static func takeOver() -> Bool {
        guard !isAllowedBeside, let id = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        let pids = replaced(others.map { ($0.processIdentifier, $0.launchDate) }, by: me.launchDate ?? Date())
        let leaving = others.filter { pids.contains($0.processIdentifier) }
        guard !leaving.isEmpty else { return true }

        let named = leaving.map(describe).joined(separator: "; ")
        leaving.forEach { $0.terminate() }
        // Asked by process number: the list of running apps isn't brought up to date while
        // this thread waits.
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            if leaving.allSatisfy({ kill($0.processIdentifier, 0) != 0 }) {
                ErrorLog.record("Launch", "Another copy of Driftcast was open (\(named)). It was closed, so that this copy (\(AppVersion.installed)) has the playlists to itself.")
                return true
            }
            usleep(50_000)
        }
        ErrorLog.record("Launch", "Another copy of Driftcast was open (\(named)) and didn't quit when asked, so this copy (\(AppVersion.installed)) made way for it.")
        ErrorLog.flush()
        leaving.first { kill($0.processIdentifier, 0) == 0 }?.activate(options: [.activateAllWindows])
        return false
    }

    /// "1.0 in /Applications": enough to find the copy and throw the older one away.
    private static func describe(_ app: NSRunningApplication) -> String {
        guard let bundle = app.bundleURL else { return "process \(app.processIdentifier)" }
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown version"
        return "\(version) in \(bundle.deletingLastPathComponent().path)"
    }
}

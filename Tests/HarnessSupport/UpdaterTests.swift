import Foundation

// The self-updater's own checks: the release notes shown in the dialog, the swap script when a
// rename is refused, what the next launch makes of a swap, staging folders left behind, and
// Cancel during the unpack and the signature check. Everything happens in a folder of its own
// under the temporary folder, with unsigned stand-ins for the app; nothing touches a real copy.
func updaterTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("driftcast-updater-tests", isDirectory: true)
    // One folder is made read-only below; a run stopped half-way would leave it so.
    func clear() {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked \"folder\"").path)
        try? fm.removeItem(at: root)
    }
    clear()
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { clear() }

    func makeBundle(_ url: URL, _ marker: String) {
        try! fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
    }
    func marker(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) }
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    // MARK: Release notes

    do {
        let json = """
        {"tag_name":"v1.2","html_url":"https://github.com/o/r/releases/tag/v1.2","draft":false,"prerelease":false,
         "body":"## 1.2\\r\\n\\r\\n### Fixed\\r\\n\\r\\n- **Opening a video** works.\\r\\n",
         "assets":[{"name":"Driftcast.zip","browser_download_url":"https://github.com/o/r/releases/download/v1.2/Driftcast.zip"}]}
        """
        if case .release(let release) = GitHubReleases.parse(data: Data(json.utf8), status: 200) {
            check(release.notes == "## 1.2\r\n\r\n### Fixed\r\n\r\n- **Opening a video** works.", "updater: release notes read from GitHub's answer: \(release.notes ?? "nil")")
        } else { check(false, "updater: release notes read from GitHub's answer") }
        let blank = json.replacingOccurrences(of: ###""body":"## 1.2\r\n\r\n### Fixed\r\n\r\n- **Opening a video** works.\r\n","###, with: ###""body":"  \r\n","###)
        if case .release(let release) = GitHubReleases.parse(data: Data(blank.utf8), status: 200) {
            check(release.notes == nil, "updater: blank release notes are none")
        } else { check(false, "updater: blank release notes are none") }

        let notes = """
        ## 1.1.3 (1 December 2026)
        <!-- written by hand -->
        ### New

        - **Rename a video:** right-click it and choose [Rename](https://example.com/rename).
        * A `code` word, __strong__ and ~~struck~~ text &amp; an <b>HTML</b> tag.
        + ![a picture](https://example.com/tracker.png)Picture gone.
        > Quoted <https://github.com/o/r> address.

        ---
        ```
        1. A numbered line stays as written.
        """
        let lines = ReleaseNotes.lines(notes)
        let expected: [ReleaseNotes.Line] = [
            .init(kind: .heading, text: "1.1.3 (1 December 2026)"),
            .init(kind: .heading, text: "New"),
            .init(kind: .bullet, text: "Rename a video: right-click it and choose Rename."),
            .init(kind: .bullet, text: "A code word, strong and struck text & an HTML tag."),
            .init(kind: .bullet, text: "Picture gone."),
            .init(kind: .text, text: "Quoted https://github.com/o/r address."),
            .init(kind: .text, text: "1. A numbered line stays as written."),
        ]
        check(lines == expected, "updater: release notes become plain headings, bullets and lines: \(lines.map(\.text))")
        check(!lines.contains { $0.text.contains("example.com") || $0.text.contains("<") || $0.text.contains("](") },
              "updater: no link address, picture or tag is left in the notes")
        let unclosed = ReleaseNotes.lines("- One\n<!-- never closed\n- Two")
        check(unclosed.map(\.text) == ["One"], "updater: an unclosed comment hides the rest, not the start: \(unclosed.map(\.text))")
        let long = ReleaseNotes.lines(String(repeating: "- A line\n", count: 500))
        check(long.count == ReleaseNotes.maximumLines, "updater: very long notes are cut (\(long.count) lines)")
    }

    // MARK: What the next launch makes of a swap

    do {
        let folder = root.appendingPathComponent("Apps folder", isDirectory: true)
        let app = folder.appendingPathComponent("Driftcast.app", isDirectory: true)
        let pending = UpdateInstaller.PendingSwap(version: "1.2", app: app.path, page: URL(string: "https://github.com/o/r/releases/tag/v1.2")!,
                                                  download: URL(string: "https://github.com/o/r/releases/download/v1.2/Driftcast.zip"))
        let aside = folder.appendingPathComponent(UpdateInstaller.stagingPrefix + UUID().uuidString).appendingPathComponent("previous.app")
        check(UpdateInstaller.afterSwap(pending, running: "1.2", at: app) == .installed
              && UpdateInstaller.afterSwap(pending, running: "1.2.0", at: app) == .installed
              && UpdateInstaller.afterSwap(pending, running: "1.3", at: app) == .installed,
              "updater: the new version running where the old one was is a swap that worked")
        check(UpdateInstaller.afterSwap(pending, running: "1.1.9", at: app) == .notInstalled,
              "updater: the old version still running there is a swap that failed")
        check(UpdateInstaller.afterSwap(pending, running: "1.1.9", at: aside) == .movedAside,
              "updater: the old copy running from its staging folder was moved aside and not put back")
        check(UpdateInstaller.afterSwap(pending, running: "1.1.9", at: root.appendingPathComponent("Downloads/Driftcast.app")) == .otherCopy
              && UpdateInstaller.afterSwap(pending, running: "1.1.9", at: folder.appendingPathComponent(".driftcast-update-x/previous.app")) == .otherCopy
              && UpdateInstaller.afterSwap(pending, running: "1.1.9", at: root.appendingPathComponent(UpdateInstaller.stagingPrefix + UUID().uuidString + "/previous.app")) == .otherCopy,
              "updater: another copy of Driftcast leaves the record for the right one")
        let suite = "com.leechsoftware.driftcast.updater-tests"
        let defaults = UserDefaults(suiteName: suite)!
        UpdateInstaller.remember(pending, in: defaults)
        let back = UpdateInstaller.pendingSwap(in: defaults)
        UpdateInstaller.forgetPendingSwap(in: defaults)
        check(back == pending && back?.release == AppRelease(version: "1.2", page: pending.page, download: pending.download)
              && UpdateInstaller.pendingSwap(in: defaults) == nil, "updater: the update handed to the script is remembered until the next launch")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Staging folders left behind

    do {
        let folder = root.appendingPathComponent("Sweep", isDirectory: true)
        let app = folder.appendingPathComponent("Driftcast.app")
        makeBundle(app, "running")
        let hourAgo = Date().addingTimeInterval(-3_600)
        func folderNamed(_ name: String, old: Bool, holding: String? = nil) -> URL {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            if let holding { makeBundle(url.appendingPathComponent(holding), "only copy") }
            if old { try! fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path) }
            return url
        }
        let leftOver = folderNamed(UpdateInstaller.stagingPrefix + UUID().uuidString, old: true, holding: "unpacked/Driftcast.app")
        let inUse = folderNamed(UpdateInstaller.stagingPrefix + UUID().uuidString, old: false, holding: "unpacked/Driftcast.app")
        let onlyCopy = folderNamed(UpdateInstaller.stagingPrefix + UUID().uuidString, old: true, holding: "previous.app")
        let notOurs = folderNamed(UpdateInstaller.stagingPrefix + "notes", old: true)
        let other = folderNamed("Other", old: true)
        let file = folder.appendingPathComponent(UpdateInstaller.stagingPrefix + UUID().uuidString)
        try! "a file".write(to: file, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: file.path)

        check(UpdateInstaller.sweepStaging(beside: folder.appendingPathComponent("Moved.app")).isEmpty && exists(leftOver),
              "updater: nothing is swept when the app isn't in its place")
        let removed = UpdateInstaller.sweepStaging(beside: app)
        check(removed.map(\.lastPathComponent) == [leftOver.lastPathComponent] && !exists(leftOver),
              "updater: a staging folder left by an earlier run is removed at launch (\(removed.map(\.lastPathComponent)))")
        check(exists(inUse), "updater: a staging folder changed in the last ten minutes is left alone (a swap may be under way)")
        check(exists(onlyCopy.appendingPathComponent("previous.app")), "updater: a staging folder holding a moved-aside copy is never removed")
        check(exists(notOurs) && exists(other) && exists(file) && marker(app) == "running", "updater: nothing else beside the app is touched")
    }

    // MARK: The swap script when a rename is refused

    do {
        // A stand-in for mv that refuses a move from or to a given path, so that each way the
        // swap can fail happens on demand.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try! """
        #!/bin/sh
        for last in "$@"; do :; done
        if [ -n "$REFUSE_FROM" ] && [ "$1" = "$REFUSE_FROM" ]; then echo "mv: $1: refused by the test" >&2; exit 1; fi
        if [ -n "$REFUSE_TO" ] && [ "$last" = "$REFUSE_TO" ]; then echo "mv: $last: refused by the test" >&2; exit 1; fi
        exec /bin/mv "$@"
        """.write(to: bin.appendingPathComponent("mv"), atomically: true, encoding: .utf8)
        let openerLog = root.appendingPathComponent("opened.txt")
        let opener = root.appendingPathComponent("opener.sh")
        try! "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"\(openerLog.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        for tool in [bin.appendingPathComponent("mv"), opener] {
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        // A process that has already ended, for the script to wait on.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! ended.run()
        ended.waitUntilExit()

        // Spaces and both kinds of quote in every path.
        var round = 0
        func swapping(refuseFrom: (URL, URL) -> URL? = { _, _ in nil }, refuseTo: (URL) -> URL? = { _ in nil })
            -> (app: URL, new: URL, staging: URL, errors: String) {
            round += 1
            let folder = root.appendingPathComponent("Round \(round) \"quoted\" it's", isDirectory: true)
            let app = folder.appendingPathComponent("Drift cast.app", isDirectory: true)
            let staging = folder.appendingPathComponent(UpdateInstaller.stagingPrefix + UUID().uuidString, isDirectory: true)
            let new = staging.appendingPathComponent("unpacked/Drift cast.app", isDirectory: true)
            makeBundle(app, "old")
            makeBundle(new, "new")
            try? fm.removeItem(at: openerLog)
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/bin/sh")
            script.arguments = ["-c", UpdateInstaller.swapScript, "driftcast-update", String(ended.processIdentifier),
                                app.path, new.path, staging.path, opener.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            environment["REFUSE_FROM"] = refuseFrom(app, new)?.path ?? ""
            environment["REFUSE_TO"] = refuseTo(app)?.path ?? ""
            script.environment = environment
            let errors = Pipe()
            script.standardError = errors
            script.standardOutput = FileHandle.nullDevice
            try! script.run()
            let said = errors.fileHandleForReading.readDataToEndOfFile()
            script.waitUntilExit()
            return (app, new, staging, String(decoding: said, as: UTF8.self))
        }

        let worked = swapping()
        check(marker(worked.app) == "new" && !exists(worked.staging) && read(openerLog) == worked.app.path + "\n",
              "updater: with spaces and quotes in the paths, the new copy goes in and is opened (\(read(openerLog)))")
        let firstRefused = swapping(refuseFrom: { app, _ in app })
        check(marker(firstRefused.app) == "old" && !exists(firstRefused.staging) && read(openerLog) == firstRefused.app.path + "\n",
              "updater: when the old copy can't be moved, it stays and reopens")
        let newRefused = swapping(refuseFrom: { _, new in new })
        check(marker(newRefused.app) == "old" && !exists(newRefused.staging) && read(openerLog) == newRefused.app.path + "\n",
              "updater: when the new copy can't go in, the old one goes back and reopens")
        let bothRefused = swapping(refuseTo: { app in app })
        let aside = bothRefused.staging.appendingPathComponent("previous.app")
        check(!exists(bothRefused.app) && marker(aside) == "old" && marker(bothRefused.new) == "new",
              "updater: when neither copy can go back in place, both are kept in the staging folder")
        check(read(openerLog) == aside.path + "\n" && bothRefused.errors.contains("Neither copy could be put in place"),
              "updater: and the old copy is opened from there, with the reason written down (\(bothRefused.errors))")
    }

    // MARK: The whole swap, with its report, when the folder can't be changed

    do {
        let folder = root.appendingPathComponent("Locked \"folder\"", isDirectory: true)
        let app = folder.appendingPathComponent("Drift cast.app", isDirectory: true)
        let staging = folder.appendingPathComponent(UpdateInstaller.stagingPrefix + UUID().uuidString, isDirectory: true)
        let new = staging.appendingPathComponent("unpacked/Drift cast.app", isDirectory: true)
        makeBundle(app, "old")
        makeBundle(new, "new")
        let openerLog = root.appendingPathComponent("opened-locked.txt")
        let opener = root.appendingPathComponent("opener-locked.sh")
        try! "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"\(openerLog.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let report = root.appendingPathComponent("Logs/Last update.txt")
        // The rename out of a folder that can't be written to is refused, as it would be if
        // macOS kept Driftcast from changing the Applications folder after it had quit.
        try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["0.3"]
        try! holder.run()
        try! UpdateInstaller.swapAfterExit(.init(installed: app, replacement: new, staging: staging), of: holder.processIdentifier,
                                           opener: opener.path, report: report)
        spin(8) { exists(openerLog) }
        spin(0.2)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        check(marker(app) == "old" && read(openerLog) == app.path + "\n", "updater: a refused swap leaves the old copy working and reopens it")
        check(read(report).contains("mv:") && read(report).contains("Permission denied"),
              "updater: what refused it is written for the next launch to log: \(read(report).trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: Cancel during the unpack and the signature check

    do {
        let source = root.appendingPathComponent("Zip source", isDirectory: true)
        makeBundle(source.appendingPathComponent("Driftcast.app"), "unsigned")
        // Says it is Driftcast, so that only the signature tells it apart.
        let info: NSDictionary = ["CFBundleIdentifier": "com.leechsoftware.driftcast", "CFBundleShortVersionString": "9.9", "CFBundlePackageType": "APPL"]
        try! info.write(to: source.appendingPathComponent("Driftcast.app/Contents/Info.plist"))
        func ditto(_ arguments: [String]) {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = arguments
            try! ditto.run()
            ditto.waitUntilExit()
        }
        let zip = root.appendingPathComponent("stand-in.zip")
        ditto(["-c", "-k", source.path, zip.path])

        let canceled = await_ { () async throws -> URL in
            let task = Task { try await UpdateInstaller.unpack(zip, into: root.appendingPathComponent("unpack-canceled")) }
            task.cancel()
            return try await task.value
        }
        var sawCancel = false
        if case .failure(let error) = canceled, error is CancellationError { sawCancel = true }
        check(sawCancel, "updater: Cancel during the unpack is a cancel, not a damaged download (\(canceled))")
        // Cancel while ditto is writing: it is stopped, which fails like a damaged zip, and was
        // shown and logged as one. 400 MB of nothing unpacks for about a second.
        let bigSource = root.appendingPathComponent("Big source", isDirectory: true)
        makeBundle(bigSource.appendingPathComponent("Driftcast.app"), "big")
        let padding = bigSource.appendingPathComponent("Driftcast.app/Contents/padding.bin")
        fm.createFile(atPath: padding.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: padding)
        try! handle.truncate(atOffset: 400 << 20)
        try! handle.close()
        let bigZip = root.appendingPathComponent("big.zip")
        ditto(["-c", "-k", bigSource.path, bigZip.path])
        try? fm.removeItem(at: bigSource)
        let stoppedFolder = root.appendingPathComponent("unpack-stopped")
        let unpacking = Task { try await UpdateInstaller.unpack(bigZip, into: stoppedFolder) }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline && !exists(stoppedFolder.appendingPathComponent("unpacked")) { usleep(1_000) }
            usleep(20_000)
            unpacking.cancel()
        }
        let stoppedUnpack = await_ { try await unpacking.value }
        var stoppedIsCancel = false
        if case .failure(let error) = stoppedUnpack, error is CancellationError { stoppedIsCancel = true }
        let written = (try? fm.attributesOfItem(atPath: stoppedFolder.appendingPathComponent("unpacked/Driftcast.app/Contents/padding.bin").path)[.size] as? Int) ?? 0
        check(stoppedIsCancel, "updater: ditto stopped by Cancel is a cancel, not a damaged download (\(stoppedUnpack), \(written >> 20) of 400 MB written)")
        try? fm.removeItem(at: stoppedFolder)
        try? fm.removeItem(at: bigZip)
        let damaged = root.appendingPathComponent("damaged.zip")
        try! Data("not a zip".utf8).write(to: damaged)
        var sawDamage = false
        if case .failure(UpdateInstaller.Failure.badArchive) = await_({ try await UpdateInstaller.unpack(damaged, into: root.appendingPathComponent("unpack-damaged")) }) { sawDamage = true }
        check(sawDamage, "updater: a damaged zip is still reported as one")

        // `prepare` beside a stand-in app: whatever stops it, nothing is left in the folder.
        let folder = root.appendingPathComponent("Prepare", isDirectory: true)
        let app = folder.appendingPathComponent("Driftcast.app")
        makeBundle(app, "installed")
        func leftOver() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(UpdateInstaller.stagingPrefix) }
        }
        let refused = await_ { try await UpdateInstaller.prepare(download: zip, replacing: app, newerThan: "0") { _ in } }
        var notSigned = false
        if case .failure(UpdateInstaller.Failure.notSigned) = refused { notSigned = true }
        check(notSigned && leftOver().isEmpty, "updater: an unsigned download is refused and its staging folder removed (\(refused))")
        let stopped = await_ { () async throws -> UpdateInstaller.Prepared in
            let task = Task { try await UpdateInstaller.prepare(download: zip, replacing: app, newerThan: "0") { _ in } }
            task.cancel()
            return try await task.value
        }
        check((try? stopped.get()) == nil && leftOver().isEmpty, "updater: a canceled update leaves no staging folder (\(stopped))")

        if let path = ProcessInfo.processInfo.environment["DRIFTCAST_RELEASE_ZIP"] {
            // The real release passes the signature check, which takes over 100 ms: Cancel is
            // pressed within a few ms of its start (the zip removed, the unpacked copy there),
            // and the copy it has checked must not be handed back or stay behind.
            let release = URL(fileURLWithPath: path)
            let task = Task { try await UpdateInstaller.prepare(download: release, replacing: app, newerThan: "0.5") { _ in } }
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    if let name = leftOver().first {
                        let staging = folder.appendingPathComponent(name)
                        if exists(staging.appendingPathComponent("unpacked")) && !exists(staging.appendingPathComponent("update.zip")) { break }
                    }
                    usleep(2_000)
                }
                task.cancel()
            }
            let outcome = await_ { try await task.value }
            if case .success(let prepared) = outcome { UpdateInstaller.discard(prepared) }
            var canceled = false
            if case .failure(let error) = outcome, error is CancellationError { canceled = true }
            check(canceled && leftOver().isEmpty, "updater: Cancel during the signature check removes the unpacked copy (\(outcome))")
        }
    }
}

import AppKit
import SwiftUI

/// Looks for a newer release on GitHub (`UpdateConfig.repository`) at launch and every eight
/// hours while running, and offers it in a dialog with the release's notes and a link to its
/// page: Update Now (downloads it, checks it is signed by Leech Software, closes Driftcast and
/// reopens the new copy; see `UpdateInstaller`), Remind Me Later (asked again eight hours on,
/// or at the next launch) or Skip This Version (never for that version). Automatic checking is
/// switched in Settings > General.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        case available(AppRelease)
        case failed
    }

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let skipped = "updateSkippedVersion"
    }

    /// How an update being installed is getting on (the dialog follows it).
    enum InstallProgress: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var install = InstallProgress.idle
    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date

    private var remindAfter: Date?
    private var remindTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var installTask: Task<Void, Never>?
    /// Counts installs started, so that one canceled but still finishing can't change what the
    /// dialog shows for the next.
    private var installRun = 0
    /// Check for Updates… chosen while the automatic check was still waiting for GitHub.
    private var manualCheckWaiting = false

    /// `-ShowAvailableUpdate YES` on the command line shows the dialog for a made-up version
    /// without touching the network, to see how it looks.
    static var showsMockedUpdate: Bool { UserDefaults.standard.bool(forKey: "ShowAvailableUpdate") }

    /// Whether there is anywhere to check; the menu item and the Settings section follow it.
    static var isAvailable: Bool { UpdateConfig.isConfigured || showsMockedUpdate || testUpdate != nil }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skipped) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skipped) }
    }

    /// Checks shortly after launch and then every eight hours, while automatic checks are on.
    /// First it sees to what an earlier run left: an update that didn't go in, and staging
    /// folders beside the app.
    func start() {
        guard Self.isAvailable, periodicTask == nil else { return }
        reportEarlierUpdate()
        let app = Bundle.main.bundleURL
        Task.detached(priority: .utility) { UpdateInstaller.sweepStaging(beside: app) }
        periodicTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                if Prefs.bool(Prefs.autoUpdateCheck) { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(UpdateConfig.checkInterval))
            }
        }
    }

    /// Check for Updates… and Check Now: a version skipped or put off earlier is offered
    /// again if it's still the newest, and the answer is always said, whatever it is.
    func checkNow() {
        guard Self.isAvailable else {
            say("No Updates Available", "This copy of Driftcast isn't linked to a release page on GitHub yet, so there is nothing to check.")
            return
        }
        skippedVersion = nil
        remindAfter = nil
        remindTask?.cancel()
        Task { await check(manual: true) }
    }

    static func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "Last check: never" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return "Last check: \(f.string(from: date))"
    }

    private func check(manual: Bool) async {
        guard status != .checking else {
            // The check under way answers it; otherwise a launch check that was still waiting
            // to fail (no internet) swallowed the request and nothing was ever said.
            if manual { manualCheckWaiting = true }
            return
        }
        status = .checking
        let outcome: GitHubReleases.Outcome
        if let zip = Self.testUpdate {
            outcome = .release(AppRelease(version: "9.9", page: URL(string: "https://github.com")!, download: zip, notes: Self.sampleNotes))
        } else if Self.showsMockedUpdate {
            outcome = .release(AppRelease(version: "9.9", page: URL(string: "https://github.com")!, download: nil, notes: Self.sampleNotes))
        } else if let repository = UpdateConfig.repositoryPath {
            outcome = await GitHubReleases.latest(repository: repository)
        } else {
            outcome = .failed
        }

        let manual = manual || manualCheckWaiting
        manualCheckWaiting = false
        if outcome != .failed {
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck)
        }
        switch outcome {
        case .release(let release) where AppVersion.isNewer(release.version, than: AppVersion.installed):
            status = .available(release)
            present(activating: manual)
        case .release, .none:
            status = .upToDate
            if manual {
                say("No Updates Available", "Driftcast \(AppVersion.installed) is the newest version.")
            }
        case .failed:
            status = .failed
            if manual {
                say("Couldn't check for updates", "Check that this Mac is connected to the internet, then try again.")
            }
        }
    }

    private func say(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Forgets the dialog once it has gone, with its watcher.
    private func letGo() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }

    /// `showing` is what the dialog opens with; `installable: false` offers only the browser.
    private func present(activating: Bool, showing state: InstallProgress = .idle, installable: Bool? = nil) {
        guard case .available(let release) = status else { return }
        if let window {
            if activating { window.makeKeyAndOrderFront(nil) }
            return
        }
        guard skippedVersion != release.version, remindAfter.map({ Date.now >= $0 }) ?? true else { return }

        install = state
        let view = UpdateDialogView(newVersion: release.version, installed: AppVersion.installed,
                                    canInstall: installable ?? UpdateInstaller.canInstall(release),
                                    notes: release.notes.map(ReleaseNotes.lines) ?? [],
                                    page: release.page) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .install:
                self.installUpdate(release)
                return   // the dialog stays up to show how it is going
            case .cancelInstall:
                self.cancelInstall()
                return
            case .browser:
                NSWorkspace.shared.open(release.download ?? release.page)
                // Not asked again this run: the download is on its way.
                self.remindAfter = .distantFuture
            case .later:
                self.remindAfter = Date.now.addingTimeInterval(UpdateConfig.checkInterval)
                self.remindTask?.cancel()
                self.remindTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(UpdateConfig.checkInterval))
                    guard !Task.isCancelled else { return }
                    self?.present(activating: false)
                }
            case .skip:
                self.skippedVersion = release.version
            }
            self.window?.close()
            self.letGo()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        // Shut with its own close button rather than a choice: let go of it all the same, or
        // the dialog would count as still open and no later check could show it again. A
        // download under way stops with it. It went on out of sight, and Driftcast then quit
        // and reopened by itself, perhaps in the middle of a film. (A choice that closes the
        // dialog lets go of it first, so this finds another window or none.)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.cancelInstall()
                self.letGo()
            }
        }
        window.center()
        window.level = .floating
        self.window = window
        if activating { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Fetches and checks the new copy, then quits; the script `UpdateInstaller` starts swaps
    /// the two and opens the new one. On any failure this copy simply carries on.
    private func installUpdate(_ release: AppRelease) {
        guard let source = release.download else { return }
        installTask?.cancel()
        installRun += 1
        let run = installRun
        install = .downloading(0)
        // Only what a DEBUG test run passes in may be older than the running copy.
        let newerThan = Self.testUpdate == nil ? AppVersion.installed : "0"
        let app = Bundle.main.bundleURL
        installTask = Task { [weak self] in
            do {
                let prepared = try await UpdateInstaller.prepare(download: source, replacing: app, newerThan: newerThan) { fraction in
                    Task { @MainActor in
                        guard let self, self.installRun == run, case .downloading = self.install else { return }
                        self.install = .downloading(fraction)
                    }
                }
                // Canceled after the last check inside `prepare`: the checked copy is thrown away.
                guard let self, self.installRun == run, !Task.isCancelled else {
                    UpdateInstaller.discard(prepared)
                    return
                }
                self.install = .installing
                try UpdateInstaller.swapAfterExit(prepared, report: UpdateInstaller.swapReport)
                // The script waits for this copy to quit, so nothing can tell yet whether the
                // swap will work; the next launch looks (`reportEarlierUpdate`).
                UpdateInstaller.remember(.init(version: UpdateInstaller.version(of: prepared.replacement) ?? release.version,
                                               app: app.path, page: release.page, download: release.download))
                NSApp.terminate(nil)
            } catch is CancellationError {
                guard let self, self.installRun == run else { return }
                self.install = .idle
            } catch {
                guard let self, self.installRun == run else { return }
                ErrorLog.record("Update", error: error)
                self.install = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops a download under way (Cancel, or the dialog closed). Whatever it had fetched or
    /// unpacked is removed by `prepare` as it stops. Once the swap has been handed to the
    /// script and Driftcast is quitting, there is nothing left to stop.
    private func cancelInstall() {
        if case .installing = install { return }
        installTask?.cancel()
        installTask = nil
        installRun += 1
        install = .idle
    }

    /// At launch, after an update was handed to the swap script: if this copy is still the old
    /// version, the swap failed after Driftcast had quit and the old copy was reopened with no
    /// word said, and the same Update Now would only fail again. So it goes in the error log,
    /// with what the script reported, and the dialog offers the download in the browser.
    private func reportEarlierUpdate() {
        guard let pending = UpdateInstaller.pendingSwap() else { return }
        let here = Bundle.main.bundleURL
        let outcome = UpdateInstaller.afterSwap(pending, running: AppVersion.installed, at: here)
        if outcome == .otherCopy { return }
        UpdateInstaller.forgetPendingSwap()
        let report = UpdateInstaller.swapReport
        let reason = (try? String(contentsOf: report, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
        try? FileManager.default.removeItem(at: report)
        let because = reason.map { $0.isEmpty ? "" : " (\($0))" } ?? ""

        let folder = URL(fileURLWithPath: pending.app).deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let message: String
        switch outcome {
        case .installed, .otherCopy:
            return
        case .notInstalled:
            ErrorLog.record("Update", "Version \(pending.version) was downloaded and checked, but couldn't be put in place of this copy (\(AppVersion.installed)) in \(folder.path)\(because).")
            message = "Driftcast couldn't replace itself with version \(pending.version). Download it in your browser, then replace this copy with it."
        case .movedAside:
            ErrorLog.record("Update", "Version \(pending.version) couldn't be put in \(folder.path), and this copy (\(AppVersion.installed)) couldn't be put back: it is now at \(here.path), with the new copy beside it\(because).")
            message = "Driftcast couldn't replace itself with version \(pending.version), and this copy couldn't be put back in \(folderName). Download the update in your browser and put it there. The error log says where this copy is now."
        }
        status = .available(pending.release)
        remindAfter = nil
        present(activating: true, showing: .failed(message), installable: false)
    }

    /// Notes for the made-up versions above, written the way the real ones are.
    private static let sampleNotes = """
    ## 9.9 (1 January 2027)

    ### New

    - **Sample feature:** a [link](https://github.com) shows as its words, and `code` as plain text.
    - **A longer line** to see how the notes wrap when a sentence runs on past the width of the box, as some do.

    ### Fixed

    - **Something that was broken** now works.
    - **Something else** is fixed too.
    - **And a third,** to show the box scrolling once there are more lines than it has room for.
    """

    /// DEBUG builds only: a local zip to install (`-UpdateTestZip /path`), to try the whole
    /// install without publishing a release.
    private static var testUpdate: URL? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "UpdateTestZip").map { URL(fileURLWithPath: $0) }
        #else
        return nil
        #endif
    }
}

/// The dialog's contents, laid out like the familiar update dialog: icon at the left, the
/// words beside it, buttons in a row.
struct UpdateDialogView: View {
    enum Choice { case install, cancelInstall, browser, later, skip }

    let newVersion: String
    let installed: String
    let canInstall: Bool
    /// The release's notes as plain lines (`ReleaseNotes`), and its page on GitHub.
    let notes: [ReleaseNotes.Line]
    let page: URL
    let answer: (Choice) -> Void
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                // The system alert's own sizes: 13 bold, then 11 regular.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Update version \(newVersion) available")
                        .font(.system(size: 13, weight: .bold))
                    Text("You have Driftcast \(installed). Click \(canInstall ? "Update Now to install" : "Download Update to get") the new version.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(canInstall
                         ? "Driftcast will download the update, close and reopen by itself. Whatever is playing will stop."
                         : "The download opens in your browser. Quit Driftcast, then replace the old copy with the new one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !notes.isEmpty { notesBox.padding(.top, 4) }
                    Link("Release page on GitHub", destination: page)
                        .font(.system(size: 11))
                }
                .padding(.top, 6)
            }
            controls
                .controlSize(.large)
                .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 560)
    }

    /// What is new, in a small box that scrolls. Only plain text: `Text(verbatim:)` reads no
    /// Markdown and the notes hold no links, so nothing in them can be opened from here.
    private var notesBox: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(notes.enumerated()), id: \.offset) { index, line in
                    switch line.kind {
                    case .heading:
                        Text(verbatim: line.text)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.top, index == 0 ? 0 : 4)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: "\u{2022}")
                            Text(verbatim: line.text).fixedSize(horizontal: false, vertical: true)
                        }
                    case .text:
                        Text(verbatim: line.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: notesHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Room for short notes as they are; longer ones scroll after about ten lines. About 70
    /// characters fit on a line of the box, 14 points high, with 3 between lines and 4 more
    /// above a heading.
    private var notesHeight: CGFloat {
        let content = notes.reduce(CGFloat(0)) { total, line in
            total + CGFloat(max(1, (line.text.count + 69) / 70)) * 14 + 3 + (line.kind == .heading ? 4 : 0)
        }
        return min(max(content, 30) + 16, 166)
    }

    @ViewBuilder private var controls: some View {
        switch updater.install {
        case .idle:
            HStack {
                Button("Skip This Version") { answer(.skip) }
                Spacer()
                Button("Remind Me Later") { answer(.later) }
                    .keyboardShortcut(.cancelAction)
                Button(canInstall ? "Update Now" : "Download Update") { answer(canInstall ? .install : .browser) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let fraction):
            HStack(spacing: 12) {
                ProgressView(value: fraction).controlSize(.regular)
                Text("Downloading \(Int(fraction * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 110, alignment: .leading)
                Button("Cancel") { answer(.cancelInstall) }
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing and reopening\u{2026}").font(.system(size: 11))
                Spacer()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Close") { answer(.later) }
                    Spacer()
                    if canInstall {
                        Button("Download in Browser") { answer(.browser) }
                        Button("Try Again") { answer(.install) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Download in Browser") { answer(.browser) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }
}

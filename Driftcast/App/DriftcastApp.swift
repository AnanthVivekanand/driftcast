import SwiftUI

@main
struct DriftcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library: Library
    @StateObject private var discovery: CastDiscovery
    @StateObject private var player: PlaybackController

    init() {
        Prefs.register()
        // One copy at a time: a copy already open is asked to save and quit before this one
        // reads the playlists (see SingleCopy). If it stays, this one leaves instead.
        if !SingleCopy.takeOver() { exit(0) }
        StreamSession.cleanTemporaryFiles()
        MediaServer.shared.start()
        let library = Library()
        let player = PlaybackController(library: library)
        _library = StateObject(wrappedValue: library)
        _discovery = StateObject(wrappedValue: CastDiscovery())
        _player = StateObject(wrappedValue: player)
        AppDelegate.player = player
        AppDelegate.library = library
    }

    var body: some Scene {
        // A single main window: opening files from Finder adds them here instead of spawning windows.
        Window("Driftcast", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(discovery)
                .environmentObject(player)
                .onAppear { discovery.start(); Updater.shared.start() }
        }
        // The first time only (macOS remembers the size after that). Tall enough that the
        // details panel shows an episode's screenshot, the show's poster and the title lines
        // under it without scrolling: the size the user's own window was at when they asked
        // for it as the default (2026-11-21; 670 high before the screenshot went on top).
        .defaultSize(width: 980, height: 746)
        .commands {
            AboutCommands()
            PlaybackCommands(player: player, library: library)
            OutputCommands(player: player, discovery: discovery)
            SubtitleCommands(player: player)
            HelpCommands()
        }
        // Files opened from the Finder go to the app delegate and nowhere else. Left to itself
        // SwiftUI answers an open by closing a single window and making it again, and closing
        // the main window quits Driftcast: with the app already running, a video
        // double-clicked in the Finder was listed and the app was gone (found 2026-11-20, in
        // 1.1.2 and before). It has to be said on the scene, and on both: the same modifier
        // on the view inside changes nothing, and with only this scene marked SwiftUI remakes
        // the Video window instead, which pauses what is playing.
        .handlesExternalEvents(matching: [])

        Window("Video", id: "video") {
            VideoWindow()
                .environmentObject(player)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 960, height: 540)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var player: PlaybackController?
    @MainActor static var library: Library?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The details panel, with the poster, is open whenever Driftcast starts (the user's
        // call, 2026-11-20); closing it lasts until the next launch.
        Prefs.defaults.set(true, forKey: Prefs.showDetails)
        MainActor.assumeIsolated {
            SubtitleSizeMenuItem.shared.install()
            VideoWindowOrder.install()
        }
        // ⌘ with an arrow is the Playback menu's (volume, next and previous video), and in a
        // text box it is how the cursor moves and text is selected: ⌘← to the start, ⇧⌘→ to
        // select to the end. The menu took them first, in every text box in the app. With the
        // keyboard in a text box they now go to the text.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let arrows: Set<UInt16> = [123, 124, 125, 126]
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            guard flags == .command, arrows.contains(event.keyCode),
                  let text = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView else { return event }
            text.keyDown(with: event)
            return nil
        }
        WatchedList.takeInOldList()
        // The red close button on the main window quits Driftcast, as the user expects of a
        // single-window player. Other windows (Video, Settings) just close.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, let id = window.identifier?.rawValue else { return }
            if id.hasPrefix("video") {
                MainActor.assumeIsolated { Self.player?.videoWindowClosed() }
            } else if id.hasPrefix("main") {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        // macOS may bring the Video window back from the last run; it is only wanted once a
        // video is playing on this Mac.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard Self.player?.nowPlaying == nil else { return }
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("video") == true {
                    window.close()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.player?.shutdown()   // records where the current video was stopped
            Self.library?.saveNow()
        }
        // A stream still starting isn't the player's yet: its ffmpeg is ended here, before
        // the folder that would have led to it is gone.
        MediaServer.shared.stopAll()
        // The Chromecast is told to close its player; a moment for that to leave this Mac.
        CastChannel.waitForClosing(upTo: 0.5)
        try? FileManager.default.removeItem(at: StreamSession.temporaryRoot)
    }

    /// Files opened from Finder ("Open With", dropping on the Dock icon) are added and played.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let player = Self.player, !player.open(urls) else { return }
            // Said, where nothing at all used to happen: a file that isn't a video, or a
            // folder with none in it.
            let alert = NSAlert()
            alert.messageText = urls.count == 1 ? "“\(urls[0].lastPathComponent)” has no video Driftcast can play" : "No videos were found"
            alert.informativeText = "Driftcast plays video and sound files, or a folder of them: MKV, MP4, AVI, MOV and most other formats."
            alert.runModal()
        }
    }
}

struct PlaybackCommands: Commands {
    @ObservedObject var player: PlaybackController
    let library: Library
    @AppStorage(Prefs.showDetails) private var showDetails = true

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // Open… plays what is chosen; Add Videos… lists it and leaves what is playing alone.
            Button("Open…") { player.chooseAndOpen() }
                .keyboardShortcut("o")
            Button("Add Videos…") { library.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Playlist") { library.newPlaylist() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // The selected video, else the playing one, in a Details window of its own.
            Button("Details") {
                if let item = player.infoItem ?? player.nowPlaying {
                    DetailsWindow.shared.show(item, player: player, library: library)
                }
            }
            .keyboardShortcut("i")
            .disabled(player.infoItem == nil && player.nowPlaying == nil)
            Button("Show in Finder") { player.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(player.nowPlaying == nil)
            Divider()
            // The list of videos played (WatchedList), as a spreadsheet saved where the person likes.
            Button("Export Watched Videos…") { WatchedList.exportCSV() }
        }
        CommandGroup(after: .sidebar) {
            // Named for what it will do, as the Finder's Show/Hide Sidebar is: a ticked
            // "Show Details" didn't read as the way to open and close the panel (the user's
            // request, 2026-11-21).
            Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePause() }
                .keyboardShortcut("p")
            Button("Stop") { player.stop() }
                .keyboardShortcut(".")
                .disabled(player.nowPlaying == nil)
            Divider()
            // Option-based so Cmd+arrows still move the cursor when renaming a playlist.
            Button("Skip Forward 10 Seconds") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(player.nowPlaying == nil)
            Button("Skip Back 10 Seconds") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(player.nowPlaying == nil)
            Button("Skip Forward 1 Minute") { player.skip(60) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
                .disabled(player.nowPlaying == nil)
            Button("Skip Back 1 Minute") { player.skip(-60) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                .disabled(player.nowPlaying == nil)
            Divider()
            Button("Next Video") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!player.hasNext)
            Button("Previous Video") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!player.hasPrevious)
            Divider()
            Button("Volume Up") { player.nudgeVolume(0.05) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { player.nudgeVolume(-0.05) }
                .keyboardShortcut(.downArrow)
            Toggle("Mute", isOn: Binding(get: { player.deviceMuted }, set: { player.setMuted($0) }))
                .disabled(player.nowPlaying == nil)
            Divider()
            // The same controls as the bar's audio button and its adjustments popover.
            Menu("Audio Track") {
                if let tracks = player.info?.audio, !tracks.isEmpty {
                    ForEach(tracks) { track in
                        Toggle(track.label, isOn: Binding(get: { player.audioIndex == track.index },
                                                          set: { if $0 { player.selectAudio(track.index) } }))
                    }
                } else {
                    // With one track the menu lists it; this is a video with none, or one
                    // that is still being read.
                    Text(player.nowPlaying == nil ? "Play a video to choose its audio track"
                         : (player.info == nil ? "Reading the video…" : "This video has no audio tracks"))
                }
            }
            Toggle("Volume Booster", isOn: Binding(get: { player.options.volumeBoost }, set: { player.setVolumeBoost($0) }))
                .disabled(player.nowPlaying == nil)
            Toggle("Downmix to Stereo", isOn: Binding(get: { player.options.downmix }, set: { player.setDownmix($0) }))
                .disabled(player.nowPlaying == nil)
            Menu("Audio Delay") {
                Text(String(format: "Current: %+.2f s", player.options.avSyncOffset))
                Button("Later by 0.05 s") { player.nudgeAVSync(0.05) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Earlier by 0.05 s") { player.nudgeAVSync(-0.05) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Reset") { player.setAVSync(0) }
                    .disabled(player.options.avSyncOffset == 0)
            }
            .disabled(player.nowPlaying == nil)
        }
    }
}

/// The Output menu: the same choices as the toolbar's output button, so the device list is
/// also where menus are expected.
struct OutputCommands: Commands {
    @ObservedObject var player: PlaybackController
    @ObservedObject var discovery: CastDiscovery

    var body: some Commands {
        CommandMenu("Output") {
            Toggle("This Mac", isOn: Binding(get: { player.output == .local && !player.isAirPlaying },
                                             set: { if $0 { player.selectOutput(.local) } }))
            Button("Apple TV or AirPlay TV…") {
                player.selectOutput(.local)
                AirPlayPicker.shared.presentSoon(openVideoWindow: player.nowPlaying == nil ? nil : { player.showVideoWindow() })
            }
            Divider()
            let screens = discovery.devices.filter { !$0.isAudioOnly }
            let speakers = discovery.devices.filter(\.isAudioOnly)
            if screens.isEmpty, speakers.isEmpty {
                Text(discovery.problem.map { "Can't search for Chromecasts: \($0)" }
                     ?? (discovery.searchedAWhile ? "No Chromecasts on this network" : "Searching for Chromecasts…"))
            }
            ForEach(screens) { device in deviceToggle(device) }
            if !speakers.isEmpty {
                Menu("Speakers (audio only)") {
                    ForEach(speakers) { device in deviceToggle(device) }
                }
            }
            Divider()
            Button("Disconnect from Chromecast") { player.disconnectCast() }
                .disabled({ if case .cast = player.output { return false }; return true }())
            Button("Search for Devices Again") { discovery.restart() }
        }
    }

    private func deviceToggle(_ device: CastDeviceInfo) -> some View {
        Toggle(device.name, isOn: Binding(get: { player.output == .cast(device) },
                                          set: { if $0 { player.selectOutput(.cast(device)) } }))
    }
}

/// Help menu: where to read about Driftcast and where to report problems.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Driftcast Help") {
                if let source = AboutWindow.sourceURL, let readme = URL(string: source.absoluteString + "#readme") {
                    NSWorkspace.shared.open(readme)
                } else {
                    AboutWindow.shared.show()
                }
            }
            if let source = AboutWindow.sourceURL {
                Button("Report a Problem…") {
                    if let issues = URL(string: source.absoluteString + "/issues") { NSWorkspace.shared.open(issues) }
                }
                Button("Driftcast on GitHub") { NSWorkspace.shared.open(source) }
            }
            Button("Driftcast Website") { NSWorkspace.shared.open(AboutWindow.website) }
            Divider()
            // What to read, or attach to a report, after something has failed.
            Button("Show Error Log") { Self.showErrorLog() }
        }
    }
}

extension HelpCommands {
    static func showErrorLog() {
        ErrorLog.flush()
        if FileManager.default.fileExists(atPath: ErrorLog.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ErrorLog.url])
        } else {
            let alert = NSAlert()
            alert.messageText = "Nothing has gone wrong yet"
            alert.informativeText = "When something fails, the reason is written to Errors.log in Library > Logs > Driftcast."
            alert.runModal()
        }
    }
}

/// The Subtitles menu in the menu bar: the same choices as the bar's subtitle button, plus
/// the online search.
struct SubtitleCommands: Commands {
    @ObservedObject var player: PlaybackController
    @AppStorage(Prefs.settingsTab) private var settingsTab = "general"
    // Read so that Larger and Smaller enable and disable as the size changes.
    @AppStorage(Prefs.subtitleScale) private var subtitleScale = 1.0

    var body: some Commands {
        CommandMenu("Subtitles") {
            if player.nowPlaying == nil {
                Text("Play a video to choose its subtitles")
            } else {
                Toggle("Off", isOn: Binding(get: { player.subtitle == nil },
                                            set: { if $0 { player.selectSubtitle(nil) } }))
                if player.subtitleChoices.isEmpty {
                    Text("This video has no subtitle tracks")
                }
                ForEach(player.subtitleChoices) { choice in
                    Toggle(choice.label, isOn: Binding(get: { player.subtitle == choice },
                                                       set: { if $0 { player.selectSubtitle(choice) } }))
                }
            }
            Divider()
            // For the video playing, else the one selected in the list: these were grayed out
            // with nothing playing, though the details panel offers both for the selected
            // video (the user's report, 2026-11-21).
            Button("Add Subtitle File…") { player.chooseSubtitleFile(for: player.subtitleTarget) }
                .disabled(player.subtitleTarget == nil)
            Button("Find Subtitles Online…") { player.showSubtitleSearch = true }
                .disabled(player.subtitleTarget == nil)
            // Listed here, not through RemoveSubtitleMenu: a menu-bar menu has no environment.
            if let target = player.subtitleTarget {
                let attached = player.removableSubtitles(for: target)
                if !attached.isEmpty {
                    Menu("Remove Subtitle") {
                        ForEach(attached, id: \.self) { file in
                            Button(SubtitleChoice.external(file).label) { player.removeSubtitleFile(file, from: target) }
                        }
                    }
                }
            }
            Button("Read Subtitles Again") { player.readSubtitlesAgain() }
                .disabled(!player.canReadSubtitlesAgain)
            Divider()
            // While AirPlaying the TV draws the subtitles at its own size, so the size
            // controls (these and SubtitleSizeMenuItem's slider) are hidden, with a line saying
            // why in their place.
            if player.isAirPlaying {
                Text(SubtitleSize.airPlayNote)
            } else {
                // The slider itself is an AppKit item that SubtitleSizeMenuItem adds under these.
                Button("Larger Subtitles") { SubtitleSize.increase() }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                    .disabled(!SubtitleSize.canIncrease)
                Button("Smaller Subtitles") { SubtitleSize.decrease() }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                    .disabled(!SubtitleSize.canDecrease)
            }
            Divider()
            // The line above keeps Settings apart from the size items (the user's request, 2026-11-21).
            Button("Subtitle Settings…") { showSubtitleSettings() }
        }
    }

    private func showSubtitleSettings() {
        settingsTab = "subtitles"
        SettingsOpener.open()
    }
}

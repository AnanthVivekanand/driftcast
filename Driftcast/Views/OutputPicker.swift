import AVKit
import Combine
import SwiftUI

/// Toolbar control choosing where video plays: this Mac (and AirPlay from there) or a Chromecast.
struct OutputPicker: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var discovery: CastDiscovery

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button {
                    player.selectOutput(.local)
                } label: {
                    // Not ticked while an AirPlay TV is showing the video.
                    Label("This Mac", systemImage: player.output == .local && !player.isAirPlaying ? "checkmark" : "laptopcomputer")
                }
                Section("Chromecast") {
                    let screens = discovery.devices.filter { !$0.isAudioOnly }
                    if screens.isEmpty {
                        Text(discovery.problem.map { "Can't search: \($0)" }
                             ?? (discovery.searchedAWhile ? "None found on this network" : "Searching the network…"))
                    }
                    ForEach(screens) { device in
                        deviceButton(device)
                    }
                }
                let speakers = discovery.devices.filter(\.isAudioOnly)
                if !speakers.isEmpty {
                    Section("Speakers (audio only)") {
                        ForEach(speakers) { device in deviceButton(device) }
                    }
                }
                Section("AirPlay") {
                    Button {
                        player.selectOutput(.local)
                        AirPlayPicker.shared.presentSoon(openVideoWindow: player.nowPlaying == nil ? nil : { player.showVideoWindow() })
                    } label: {
                        Label("Apple TV or AirPlay TV…", systemImage: "airplayvideo")
                    }
                }
                if case .cast = player.output {
                    Divider()
                    Button("Disconnect") { player.disconnectCast() }
                }
                Divider()
                Button("Search Again") { discovery.restart() }
            } label: {
                Label(player.outputName, systemImage: player.outputSymbol)
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose where to play")

            if player.output == .local {
                Button {
                    AirPlayPicker.shared.present(openVideoWindow: player.nowPlaying == nil ? nil : { player.showVideoWindow() })
                } label: {
                    Image(systemName: "airplayvideo")
                        .foregroundStyle(player.isAirPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.borderless)
                .frame(width: 30, height: 22)
                // The toolbar's own picker, unseen: the fallback when the video window's isn't there.
                .background(AirPlayButton(player: player.localTarget.player).opacity(0).allowsHitTesting(false))
                .help("AirPlay to an Apple TV or AirPlay 2 TV")
                .accessibilityLabel("AirPlay")
            }
        }
    }
}

extension OutputPicker {
    fileprivate func deviceButton(_ device: CastDeviceInfo) -> some View {
        Button {
            player.selectOutput(.cast(device))
        } label: {
            Label(device.name, systemImage: player.output == .cast(device) ? "checkmark" : device.symbol)
        }
    }
}

struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        AirPlayPicker.shared.view = v
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        AirPlayPicker.shared.view = nsView
    }
}

/// Opens the system's list of AirPlay devices. Only an AVRoutePickerView can show it, and only
/// the one AVKit puts in the video window's own controls moves the video: a picker the app makes
/// (the toolbar's) lists the same devices, but choosing a TV there leaves the video on the Mac
/// (seen on macOS 26, also with `prioritizesVideoDevices` set like AVKit's). So the toolbar's
/// AirPlay button and the output menus click the video window's button on the user's behalf.
@MainActor
final class AirPlayPicker {
    static let shared = AirPlayPicker()
    /// The toolbar's own picker: the fallback when the video window has no AirPlay button
    /// (nothing playing, or already AirPlaying, when the window shows the casting picture).
    weak var view: AVRoutePickerView?

    /// Waits for the menu to close and, when switching away from a Chromecast, for the player
    /// to come back into the video window.
    func presentSoon(openVideoWindow: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.present(openVideoWindow: openVideoWindow) }
    }

    /// `openVideoWindow` is given when a video is loaded: with its window closed, the window is
    /// opened first and its button clicked once it's there.
    func present(openVideoWindow: (() -> Void)? = nil) {
        if let button = Self.videoWindowButton() {
            button.window?.makeKeyAndOrderFront(nil)
            button.performClick(nil)
        } else if let openVideoWindow, !PlaybackController.videoWindowIsOpen {
            openVideoWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.present() }
        } else if let view, view.window != nil, let button = Self.firstButton(in: view) {
            button.performClick(nil)
        }
    }

    /// The AirPlay button inside the video window's AVPlayerView. It stays in place and enabled
    /// while the floating controls are faded out (only a parent's opacity changes).
    private static func videoWindowButton() -> NSButton? {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("video") == true && $0.isVisible && !$0.isMiniaturized }),
              let content = window.contentView, let playerView = first(AVPlayerView.self, in: content),
              let picker = first(AVRoutePickerView.self, in: playerView), !picker.isHiddenOrHasHiddenAncestor,
              let button = firstButton(in: picker), button.isEnabled else { return nil }
        return button
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let match = sub as? T { return match }
            if let found = first(type, in: sub) { return found }
        }
        return nil
    }

    private static func firstButton(in view: NSView) -> NSButton? { first(NSButton.self, in: view) }
}

/// The local/AirPlay picture. When AirPlay is active AVPlayerView shows its own placeholder.
/// A thin bar under the picture says which closed captions the video has, when it has any
/// (unless Settings hide it).
struct VideoWindow: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false

    /// DEBUG builds can show the watermark with no device to hand (`-PreviewCastingWatermark Name`).
    private var castingName: String? {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "PreviewCastingWatermark") { return name }
        #endif
        return player.remoteDeviceName
    }

    /// The bar under the picture (captions line, or the casting controls), as laid out.
    @State private var barHeight: CGFloat = 0
    /// The size of the picture on show, which the window takes its shape from.
    @StateObject private var picture = PictureSize()
    /// The room the window had when the person began to resize it.
    @State private var roomBeforeResize: NSSize?

    /// The player whose picture is in the window: this Mac's, or while casting the silent copy.
    private var shownPlayer: AVPlayer { castingName == nil ? player.localTarget.player : player.mirror.player }

    /// The captions bar is for a video that has captions to choose from. With none, a bar saying
    /// so only took room from the picture (the user's call, 2026-11-19); Find Subtitles Online…
    /// is still in the Subtitles menu and behind the playback bar's button.
    /// It also shows, for a video with none, when subtitles were found online, so the mark
    /// offering them has a place (the user's request, 2026-11-21).
    private var showsCaptionsBar: Bool {
        guard !hideNotices, let item = player.nowPlaying else { return false }
        if !player.subtitleChoices.isEmpty { return true }
        return OnlineSubtitleLookup.shared.offer(for: item.url, language: subtitleLanguage) != nil
    }
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = ""
    @ObservedObject private var online = OnlineSubtitleLookup.shared

    /// The playing video, once the player has read its list of captions, when none is in the
    /// subtitle language: looked up online whether or not the details panel is open.
    private var lookupKey: String {
        guard let item = player.nowPlaying, player.info != nil, !hideNotices, !subtitleLanguage.isEmpty,
              !SubtitleChoice.hasAny(player.subtitleChoices, in: subtitleLanguage) else { return "" }
        return item.url.path + "|" + subtitleLanguage
    }

    fileprivate var pictureMinimum: CGSize {
        castingName == nil ? CGSize(width: 480, height: 270) : CGSize(width: 320, height: 140)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let name = castingName {
                    // A silent copy of the video under the overlay, following the TV.
                    CastingPicture(mirror: player.mirror, deviceName: name, artwork: player.artwork)
                } else {
                    LocalPicture(avPlayer: player.localTarget.player)
                }
            }
            .frame(minWidth: pictureMinimum.width, minHeight: pictureMinimum.height)
            .background(.black)
            // A VStack, not a Group: a Group would hand the measuring background to each child.
            VStack(spacing: 0) {
                if castingName != nil {
                    // All this window is for while casting: is it playing, and where.
                    Divider()
                    CastingControls()
                } else if showsCaptionsBar {
                    Divider()
                    CaptionsFooter()
                }
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { barHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { barHeight = $0 }
            })
        }
        .task(id: lookupKey) {
            guard !lookupKey.isEmpty, let item = player.nowPlaying else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await online.look(for: item, language: subtitleLanguage)
        }
        .onAppear {
            fitWindow(casting: castingName != nil)
            keepBarVisible()
            picture.watch(shownPlayer)
            DispatchQueue.main.async { VideoWindowOrder.placeBeside(); VideoWindowOrder.raise() }
            fitPicture()
        }
        .onChange(of: castingName != nil) { casting in
            fitWindow(casting: casting)
            picture.watch(shownPlayer)
        }
        .onChange(of: barHeight) { _ in keepBarVisible(); fitPicture() }
        .onChange(of: picture.size) { _ in fitPicture() }
        // A resize by hand ends in the picture's shape too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
            if let window = note.object as? NSWindow, window === Self.window { roomBeforeResize = window.contentLayoutRect.size }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            if (note.object as? NSWindow) === Self.window { fitPicture(resizedFrom: roomBeforeResize) }
        }
        // A size macOS puts back after the window opens is checked like any other.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("video") == true { keepBarVisible() }
        }
        .onChange(of: player.nowPlaying?.url) { _ in keepBarVisible() }
        .background(WindowConfigurator { window in
            // Opened by the app when a video starts, never brought back by macOS at launch.
            window.isRestorable = false
        })
        .navigationTitle(player.output == .local ? (player.nowPlaying?.displayName ?? "Video") : "Video")
    }
}

/// The window drops to half its size while casting, keeping its top-left corner where it is,
/// and goes back when playback returns to this Mac.
extension VideoWindow {
    /// Kept in the defaults so that quitting mid-cast doesn't leave the window small for good.
    private static let sizeBeforeCastingKey = "videoWindowSizeBeforeCasting"

    fileprivate func fitWindow(casting: Bool) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("video") == true }) else { return }
        let defaults = UserDefaults.standard
        let wanted: NSSize
        if casting {
            guard defaults.string(forKey: Self.sizeBeforeCastingKey) == nil else { return }
            let current = window.contentLayoutRect.size
            defaults.set(NSStringFromSize(current), forKey: Self.sizeBeforeCastingKey)
            wanted = NSSize(width: max(400, current.width / 2), height: max(225, current.height / 2))
        } else {
            guard let saved = defaults.string(forKey: Self.sizeBeforeCastingKey) else { return }
            defaults.removeObject(forKey: Self.sizeBeforeCastingKey)
            wanted = NSSizeFromString(saved)
        }
        window.setFrame(Self.frame(of: window, withRoom: wanted), display: true, animate: true)
        keepBarVisible()
    }

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("video") == true }
    }

    /// Shapes the window to the picture, so that no black bars stand beside it or above and
    /// below it. The window's first size (960 by 540, title bar included) left a bar down each
    /// side of a 16:9 video, and a film in another shape had bars whatever the size (the
    /// user's report, 2026-11-20: "the video height doesn't fit in the window").
    ///
    /// The width stays and the height follows it; after a resize by the top or bottom edge
    /// alone it is the height that stays. The top-left corner keeps its place. Not in full
    /// screen, nor in a window zoomed to fill the screen, where bars are what is expected.
    fileprivate func fitPicture(resizedFrom before: NSSize? = nil) {
        DispatchQueue.main.async {
            guard let window = Self.window, !window.styleMask.contains(.fullScreen), !window.inLiveResize,
                  !window.isZoomed, picture.size.width > 0, picture.size.height > 0 else { return }
            let shape = picture.size.width / picture.size.height
            let room = window.contentLayoutRect.size
            var width = room.width
            if let before, abs(room.width - before.width) < 1, abs(room.height - before.height) >= 1 {
                width = (room.height - barHeight) * shape
            }
            // No more than the screen has below and to the right of the window's corner, so
            // the corner can stay where it is.
            var most = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if let screen = window.screen?.visibleFrame {
                most = NSSize(width: screen.maxX - window.frame.minX,
                              height: window.frame.maxY - screen.minY - Self.chrome(of: window))
            }
            let fitted = VideoWindowGeometry.room(forShape: shape, width: width, bar: barHeight, minimum: pictureMinimum, most: most)
            guard abs(fitted.width - room.width) > 0.5 || abs(fitted.height - room.height) > 0.5 else { return }
            window.setFrame(Self.frame(of: window, withRoom: fitted), display: true, animate: false)
        }
    }

    /// The height of the window that isn't room for the picture and the bar: its title bar.
    /// SwiftUI lets this window's content run under the title bar, so the window's own
    /// arithmetic (`frameRect(forContentRect:)`, `contentMinSize`) counts that strip as room.
    /// Sizes here are the room below the title bar, and this is added to make a frame.
    static func chrome(of window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    /// The frame that leaves `room` below the title bar, the top-left corner staying where it is.
    static func frame(of window: NSWindow, withRoom room: NSSize) -> NSRect {
        let size = NSSize(width: room.width, height: room.height + chrome(of: window))
        return NSRect(origin: NSPoint(x: window.frame.minX, y: window.frame.maxY - size.height), size: size)
    }

    /// The window can't be smaller than the picture's minimum plus the bar under it. A saved or
    /// restored size can be (the bar only appears once a video plays), which cut the bar off at
    /// the bottom; the window then grows downwards, keeping its top-left corner.
    fileprivate func keepBarVisible() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("video") == true }) else { return }
            let needed = NSSize(width: pictureMinimum.width, height: pictureMinimum.height + barHeight)
            // The smallest frame, title bar included, in the terms the window keeps its minimum in.
            let smallest = Self.frame(of: window, withRoom: needed)
            window.contentMinSize = window.contentRect(forFrameRect: smallest).size
            let current = window.contentLayoutRect.size
            guard current.height < needed.height - 0.5 || current.width < needed.width - 0.5 else { return }
            let room = NSSize(width: max(current.width, needed.width), height: max(current.height, needed.height))
            window.setFrame(Self.frame(of: window, withRoom: room), display: true, animate: false)
        }
    }
}

/// The size of the picture a player is showing, kept up to date: a video's shape is known only
/// once its first frames are in, and the next video's may differ. The last size known stays
/// while nothing is loaded.
@MainActor
final class PictureSize: ObservableObject {
    @Published private(set) var size = CGSize.zero
    private var watching: AnyCancellable?
    private weak var player: AVPlayer?

    func watch(_ player: AVPlayer) {
        guard player !== self.player else { return }
        self.player = player
        watching = player.publisher(for: \.currentItem?.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    guard let self, let size, size.width > 0, size.height > 0, size != self.size else { return }
                    self.size = size
                }
            }
    }
}

/// Play and pause and the timeline, for a video that is playing on another device.
private struct CastingControls: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        HStack(spacing: 6) {
            // Previous and Next beside Play, as in the playback bar (the user's report,
            // 2026-11-20: the video window had nothing for the next or previous video).
            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!player.hasPrevious)
            .help("Previous video, or back to the start")
            .accessibilityLabel("Previous video, or back to the start")
            Button { player.togglePause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.end.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!player.hasNext)
            .help("Next video")
            .accessibilityLabel("Next video")
            TimelineRow(clock: player.clock)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The video window's picture while a TV plays the video: the mirror's silent copy, under a gray
/// veil with who it is playing on. Until the copy has a picture, the poster stands in. In the
/// lower left corner, where the video is and how long is left of it.
private struct CastingPicture: View {
    @EnvironmentObject private var player: PlaybackController
    @ObservedObject var mirror: CastingMirror
    let deviceName: String
    let artwork: NSImage?

    var body: some View {
        ZStack {
            PlayerViewRepresentable(player: mirror.player, showsControls: false, updatesNowPlaying: false)
            CastingWatermark(deviceName: deviceName, artwork: artwork, overVideo: mirror.hasPicture,
                             details: player.nowPlaying == nil ? nil : CastingDetails(plan: player.plan))
            if player.nowPlaying != nil {
                CastingTime(clock: player.clock)
            }
        }
    }
}

/// The time in the casting picture's corner. Apart from the picture and the watermark because
/// it redraws at every position update and they need not.
private struct CastingTime: View {
    @EnvironmentObject private var player: PlaybackController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        CastingTimeLabel(time: TimeLeft(position: clock.position, duration: player.duration,
                                        creditsStart: player.info?.creditsStart))
    }
}

/// The video window's footer: "Closed Captions: English, Spanish" (or that there are none)
/// and the same menu as the playback bar's subtitle button. Full screen shows the picture
/// alone, since AVPlayerView takes only itself full screen.
struct CaptionsFooter: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage(Prefs.subtitleLanguage) private var language = ""

    /// Nothing in the Settings language, forced tracks included: the crossed-out mark (the menu offers Find Subtitles Online…).
    private var missing: Bool { !language.isEmpty && !SubtitleChoice.hasAny(player.subtitleChoices, in: language) }

    var body: some View {
        HStack(spacing: 8) {
            CaptionsIcon(missing: missing, filled: player.subtitle != nil, size: 18)
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)   // a quiet note under the picture, not a heading
                .lineLimit(1)
                .truncationMode(.tail)
            if missing, let item = player.nowPlaying {
                FoundSubtitlesBadge(item: item, language: language, seeAll: { player.showSubtitleSearch = true })
            }
            Spacer(minLength: 12)
            Menu {
                SubtitleMenuItems()
            } label: {
                // "English (forced)" for a signs-only track, so it doesn't contradict "No English captions".
                Text(player.subtitle.map { ($0.isForced ? "\(Lang.name($0.language) ?? "On") (forced)" : Lang.name($0.language)) ?? "On" } ?? "Off")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Closed captions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var notice: String {
        let languages = SubtitleChoice.languageSummary(player.subtitleChoices)
        if player.subtitleChoices.isEmpty { return "No closed captions" }
        if missing { return "No \(Lang.name(language) ?? language) captions" }   // the menu lists what there is
        return "Closed Captions: \(languages)"
    }
}

/// Off, every track and file, then the ways to add one: the body of the subtitle menus in the
/// playback bar and the video window's footer.
struct SubtitleMenuItems: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        Button { player.selectSubtitle(nil) } label: {
            if player.subtitle == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
        }
        if !player.subtitleChoices.isEmpty { Divider() }
        ForEach(player.subtitleChoices) { choice in
            Button { player.selectSubtitle(choice) } label: {
                if choice == player.subtitle { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
            }
        }
        Divider()
        Button("Find Subtitles Online…") { player.showSubtitleSearch = true }
        Button("Add Subtitle File…") { player.chooseSubtitleFile() }
        if player.canReadSubtitlesAgain { Button("Read Subtitles Again") { player.readSubtitlesAgain() } }
        Divider()
        SubtitleSizeMenu()
    }
}

/// Runs a closure on the NSWindow that ends up hosting the view.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { configure(window) }
    }
}

/// The picture on this Mac, with Driftcast's own controls over its foot in place of macOS's.
///
/// macOS's controls gray out Fast Forward and Rewind for a stream made as it plays (they need
/// a keyframe index, which such a stream doesn't have), and can't be given buttons of their
/// own, so Next and Previous had nowhere to go (the user's reports and choice, 2026-11-20:
/// Driftcast's own bar). It has what the playback bar has: Previous, back 10 seconds, Play,
/// forward 10 seconds, Next, the timeline, and the speaker, with full screen at its end. Like
/// the system's bar it comes up when the pointer moves over the picture and goes a few seconds
/// after it stops, staying while the pointer is on it or the video is paused. A double-click on
/// the picture goes full screen and back.
private struct LocalPicture: View {
    @EnvironmentObject private var player: PlaybackController
    let avPlayer: AVPlayer
    @State private var shown = true
    @State private var onBar = false
    /// Counts movements, so that only the last one's wait hides the bar.
    @State private var moves = 0

    private var keepShowing: Bool { onBar || !player.isPlaying }

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerViewRepresentable(player: avPlayer, showsControls: false, updatesNowPlaying: true)
            // Takes the double-click; the picture itself has nothing else to click now.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { VideoControls.toggleFullScreen() }
            if (shown || keepShowing), player.nowPlaying != nil {
                VideoControls()
                    .onHover { onBar = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !shown { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
                moves += 1
                let move = moves
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { hideAfterWait(move) }
            case .ended:
                if !keepShowing { withAnimation(.easeIn(duration: 0.3)) { shown = false } }
            }
        }
        .onAppear {
            let move = moves
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { hideAfterWait(move) }
        }
    }

    private func hideAfterWait(_ move: Int) {
        guard move == moves, !keepShowing else { return }
        withAnimation(.easeIn(duration: 0.3)) { shown = false }
        // In full screen the pointer goes as well, until it moves.
        if VideoWindow.window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

/// The bar over the foot of the picture on this Mac.
private struct VideoControls: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var fullScreen = VideoWindow.window?.styleMask.contains(.fullScreen) == true

    static func toggleFullScreen() { VideoWindow.window?.toggleFullScreen(nil) }

    var body: some View {
        VStack(spacing: 4) {
            TimelineRow(clock: player.clock)
            HStack(spacing: 0) {
                Button { player.setMuted(!player.deviceMuted) } label: {
                    Image(systemName: player.deviceMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28)
                }
                .help(player.deviceMuted ? "Unmute" : "Mute")
                .accessibilityLabel(player.deviceMuted ? "Unmute" : "Mute")
                Spacer(minLength: 8)
                HStack(spacing: 20) {
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                        .disabled(!player.hasPrevious)
                        .help("Previous video, or back to the start")
                        .accessibilityLabel("Previous video, or back to the start")
                    Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                        .help("Back 10 seconds")
                        .accessibilityLabel("Back 10 seconds")
                    Button { player.togglePause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .frame(width: 28)
                    }
                    .help(player.isPlaying ? "Pause" : "Play")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                        .help("Forward 10 seconds")
                        .accessibilityLabel("Forward 10 seconds")
                    Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                        .disabled(!player.hasNext)
                        .help("Next video")
                        .accessibilityLabel("Next video")
                }
                Spacer(minLength: 8)
                Button { Self.toggleFullScreen() } label: {
                    Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 28)
                }
                .help(fullScreen ? "Exit Full Screen" : "Enter Full Screen")
                .accessibilityLabel(fullScreen ? "Exit Full Screen" : "Enter Full Screen")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === VideoWindow.window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === VideoWindow.window { fullScreen = false }
        }
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// Off for both pictures since 1.1.3: on this Mac Driftcast's own bar stands in for them,
    /// and on the casting copy they would act on the copy, not on the TV.
    var showsControls = true
    /// Off for the casting copy: it is not what is playing, and must not claim Now Playing or
    /// the media keys.
    var updatesNowPlaying = true

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = showsControls ? .floating : .none
        v.showsFullScreenToggleButton = showsControls
        v.allowsPictureInPicturePlayback = showsControls
        v.updatesNowPlayingInfoCenter = updatesNowPlaying
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

import AppKit
import Combine
import MediaPlayer
import SwiftUI

enum PlaybackOutput: Hashable {
    case local
    case cast(CastDeviceInfo)
}

/// The values that change several times a second, kept apart so that only the timeline
/// redraws for them and not every view that looks at the player.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    /// File-time range the device can seek within without restarting the converter.
    @Published var seekableRange: ClosedRange<Double> = 0...0
}

/// The app's single source of truth for what's playing and where.
///
/// Positions shown in the UI are always file positions. A converted (HLS) stream may start
/// part-way into the file after a seek past what's been converted, so device time is offset
/// by `StreamSession.offset`.
@MainActor
final class PlaybackController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case buffering
        case playing
        case paused
        case failed(String)
    }

    let library: Library
    let localTarget = AVPlayerTarget()
    /// The silent picture in the video window while a TV plays the video.
    let mirror = CastingMirror()
    /// What the device was given to play, which the mirror plays too.
    private var streamURL: URL?

    let clock = PlaybackClock()
    var position: Double {
        get { clock.position }
        set { clock.position = newValue }
    }
    private var seekableRange: ClosedRange<Double> {
        get { clock.seekableRange }
        set { if clock.seekableRange != newValue { clock.seekableRange = newValue } }
    }

    @Published private(set) var output: PlaybackOutput = .local
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nowPlaying: MediaItem?
    @Published private(set) var info: MediaInfo?
    @Published private(set) var plan: StreamPlan?
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 1
    /// The device's own mute (a TV muted with its remote, this Mac's player muted from the
    /// bar), which the bar's speaker shows.
    @Published private(set) var deviceMuted = false
    /// The connection to the Chromecast dropped and is being remade; the bar says so.
    @Published private(set) var castReconnecting = false
    @Published private(set) var audioIndex: Int?
    @Published private(set) var subtitleChoices: [SubtitleChoice] = []
    @Published private(set) var subtitle: SubtitleChoice?
    @Published private(set) var options = PlaybackOptions()
    @Published private(set) var isAirPlaying = false
    /// Set when an AirPlay TV has connected but never asks this Mac for the video.
    @Published private(set) var airPlayProblem: String?
    /// The poster or a frame of what's playing, behind the watermark while casting.
    @Published private(set) var artwork: NSImage?
    /// Incremented when local playback starts so the UI opens the video window.
    @Published private(set) var videoWindowRequest = 0
    var isScrubbing = false
    /// What the TV's pause and seek panel shows for the video playing (`MediaItem.tvLines`).
    private var tvLines: (title: String, subtitle: String?)?
    /// Whether those lines were made for a film found online with its poster card on.
    private var tvLookedUp = false
    /// Set by the Subtitles menu or the bar's subtitle button to open the online search sheet.
    @Published var showSubtitleSearch = false
    /// The video whose Media Info sheet should be open (File menu and right-click menu).
    @Published var infoItem: MediaItem?
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var queueIndex = 0

    private var castTarget: CastTarget?
    /// The subtitle size the output was last told about, so a change in Settings or the
    /// Subtitles menu is passed on once, as it happens.
    private var appliedSubtitleScale = SubtitleSize.current
    private var session: StreamSession?
    private var loadToken = 0
    /// The load under way. A newer one, Stop and a change of screen cancel it, so that what it
    /// was waiting for (ffmpeg reading the file, a lookup) ends now and not when it would have.
    private var loadTask: Task<Void, Never>?
    /// The video whose sound track and first subtitle haven't been chosen yet. A load started
    /// again before it got that far (a seek while the video was opening, a setting changed)
    /// still owes it; without this the video came up with the last video's choices.
    private var tracksOwed: MediaItem.ID?
    /// The video that hasn't yet been entered in the watched list or shown its poster card.
    /// Owed across a restarted load in the same way, and gone once the video has started, so
    /// that a seek or a change of track mid-film brings no second card.
    private var firstStartOwed: MediaItem.ID?
    /// A video marked watched or unwatched by hand while it plays. The mark is the last word:
    /// where the video had got to isn't saved over it five seconds later.
    private var progressSetByHand: URL?
    private var librarySync: AnyCancellable?
    private var lastProgressSave = Date.distantPast
    private var lastVolumeChange = Date.distantPast
    private var housekeeping: Timer?
    /// When the AirPlay device should have started fetching the current stream.
    private var airPlayExpectedSince: Date?
    private var syncWork: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var settingsWork: Task<Void, Never>?
    private var plannedSettings: EncoderSettings?
    /// The subtitle the next video starts with when the details panel picked one before pressing Play.
    private var startSubtitle: SubtitleStart = .automatic
    /// Videos OpenSubtitles has already been asked about in this run (found or not).
    private var autoSearched: Set<URL> = []

    /// How a video's first subtitle is chosen: the language rules in Settings, none, or a track
    /// the user picked before playback started.
    enum SubtitleStart: Sendable {
        case automatic
        case off
        case use(SubtitleChoice)
    }

    init(library: Library) {
        self.library = library
        localTarget.onStatus = { [weak self] s in self?.handle(s, from: .local) }
        localTarget.onExternalChange = { [weak self] active in
            guard let self else { return }
            self.isAirPlaying = active
            self.airPlayExpectedSince = active ? Date() : nil
            self.airPlayProblem = nil
            // AirPlay ended (from the TV, say) and AVPlayer carries on here: with the video
            // window closed that would be sound from a video nobody can see. AirPlay can also
            // report a stop for a moment while connecting, so look again after a pause.
            if !active {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, !self.localTarget.isExternal else { return }
                    self.pauseIfUnseen()
                }
            }
        }
        setupRemoteCommands()
        // Published as the list is about to change, with the list it changes to.
        librarySync = library.$playlists.sink { [weak self] playlists in self?.syncQueue(with: playlists) }
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Conversion settings changed in Settings: re-plan the current stream (debounced, since
    /// SwiftUI writes each keystroke of a text field).
    private func settingsChanged() {
        let scale = SubtitleSize.current
        if abs(scale - appliedSubtitleScale) > 0.001 {
            appliedSubtitleScale = scale
            target.setSubtitleScale(scale)
        }
        guard let planned = plannedSettings, EncoderSettings.current() != planned else { return }
        settingsWork?.cancel()
        settingsWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.nowPlaying != nil else { return }
            self.reload()
        }
    }

    /// Keeps the Mac awake while a stream is being served to a device.
    private func setStreaming(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Streaming video to a device")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private var target: PlaybackTarget {
        if case .cast = output, let c = castTarget { return c }
        return localTarget
    }

    var isPlaying: Bool { phase == .playing || phase == .buffering }
    var isBusy: Bool { if case .preparing = phase { return true }; return phase == .buffering }

    var outputName: String {
        switch output {
        case .local: return isAirPlaying ? "AirPlay" : "This Mac"
        case .cast(let d): return d.name
        }
    }

    /// The device a video is being sent to, when it isn't playing on this Mac.
    var remoteDeviceName: String? {
        guard nowPlaying != nil else { return nil }
        switch output {
        case .cast(let d): return d.name
        case .local: return isAirPlaying ? "AirPlay TV" : nil
        }
    }

    var outputSymbol: String {
        switch output {
        case .local: return isAirPlaying ? "airplayvideo" : "laptopcomputer"
        case .cast(let d): return d.symbol
        }
    }

    var statusText: String {
        if castReconnecting, case .cast(let d) = output { return "Reconnecting to \(d.name)…" }
        switch phase {
        // Under "Nothing playing", so it says what to do rather than the same again.
        case .idle: return nowPlaying == nil ? "Double-click a video to play it" : "Stopped"
        case .preparing(let s): return s
        case .buffering: return airPlayProblem == nil ? "Buffering on \(outputName)…" : "The TV can't reach this Mac"
        case .playing: return airPlayProblem == nil ? "Playing on \(outputName)" : "The TV can't reach this Mac"
        case .paused: return "Paused on \(outputName)"
        case .failed(let s): return s
        }
    }

    // MARK: Output selection

    func selectOutput(_ newOutput: PlaybackOutput) {
        guard newOutput != output else {
            // The same TV chosen again after a failure: the video is tried again over the
            // connection there is, which is not closed and made afresh.
            if case .cast = output, case .failed = phase, let item = nowPlaying { start(item, at: position, fresh: false) }
            return
        }
        let resumeItem = nowPlaying
        let resumeAt = position
        loadToken += 1
        loadTask?.cancel()
        castReconnecting = false
        deviceMuted = false
        target.stop()
        teardownSession()
        if case .cast = output {
            castTarget?.disconnect()
            castTarget = nil
        }
        output = newOutput
        if case .cast(let device) = newOutput {
            let t = CastTarget(device: device)
            t.onStatus = { [weak self] s in self?.handle(s, from: newOutput) }
            castTarget = t
        }
        if let item = resumeItem {
            start(item, at: resumeAt, fresh: false)
        } else {
            phase = .idle
        }
    }

    /// Ends the Chromecast session (closes the player on the TV) and returns to this Mac.
    func disconnectCast() {
        stop()
        selectOutput(.local)
    }

    // MARK: Starting playback

    func play(_ item: MediaItem, queue items: [MediaItem], fromBeginning: Bool = false, subtitle: SubtitleStart = .automatic) {
        queue = items
        queueIndex = items.firstIndex { $0.id == item.id } ?? 0
        if fromBeginning {
            library.clearProgress(item.url)
            // The video playing, started over: where it had got to isn't saved back as the
            // place to resume from (a place under ten seconds is never saved).
            if nowPlaying?.url == item.url { position = 0 }
        }
        startSubtitle = subtitle
        infoItem = item
        start(item, at: fromBeginning ? 0 : resumePoint(for: item), fresh: true)
    }

    private func resumePoint(for item: MediaItem) -> Double {
        guard Prefs.bool(Prefs.resumePlayback) else { return 0 }
        return library.resumePosition(for: item.url) ?? 0
    }

    /// `fresh` is a video picked or reached in the playlist, not one loaded again after a seek
    /// or a change of track or screen. `paused` loads it without playing (a Chromecast
    /// rejoined after its connection dropped while the video was paused).
    private func start(_ item: MediaItem, at time: Double, fresh: Bool, paused: Bool = false) {
        saveProgress(force: true)
        // The details panel follows playback unless another video was picked out in the list.
        if infoItem == nil || infoItem?.id == nowPlaying?.id { infoItem = item }
        if fresh {
            tracksOwed = item.id
            firstStartOwed = item.id
            progressSetByHand = nil
        }
        castReconnecting = false
        loadToken += 1
        let token = loadToken
        loadTask?.cancel()
        loadTask = Task { await prepareAndLoad(item, at: time, paused: paused, token: token) }
    }

    private func prepareAndLoad(_ item: MediaItem, at time: Double, paused: Bool, token: Int) async {
        teardownSession()
        if nowPlaying?.id != item.id {
            // Another video: the last one's length, tracks and artwork aren't shown under its
            // name while it opens, and its length can't be saved as this one's (which could
            // mark a video watched that had only just been opened).
            info = nil
            plan = nil
            duration = 0
            artwork = nil
            subtitleChoices = []
            subtitle = nil
            audioIndex = nil
        }
        nowPlaying = item
        tvLookedUp = false
        tvLines = item.tvLines(lookedUp: false)
        position = time
        seekableRange = time...time
        phase = .preparing("Opening \(item.displayName)…")
        var created: StreamSession?

        func stale() -> Bool {
            guard token != loadToken else { return false }
            if let created, created !== session {
                MediaServer.shared.unregister(created)
                created.stop()
            }
            return true
        }

        do {
            guard FFmpeg.isAvailable else { throw FFmpegError.notFound }
            guard item.exists else { throw FFmpegError.failed("\(item.url.lastPathComponent) couldn't be found. It may have been moved or deleted.") }
            let info = try await MediaProbe.shared.probe(item.url)
            if stale() { return }
            self.info = info
            duration = info.duration
            if tracksOwed == item.id {
                subtitleChoices = SubtitleChoice.available(for: item, info: info)
                audioIndex = Self.preferredAudio(info)?.index
                let audio = info.audio.first { $0.index == audioIndex }
                let automatic = Self.preferredSubtitle(subtitleChoices, audio: audio)
                var searchOnline = false
                switch startSubtitle {
                case .automatic:
                    subtitle = automatic
                    // A forced track may have come on; the search still looks for a full one.
                    searchOnline = !autoSearched.contains(item.url)
                        && Self.shouldSearchOnline(choices: subtitleChoices, audio: audio)
                case .off: subtitle = nil
                case .use(let choice): subtitle = subtitleChoices.contains(choice) ? choice : automatic
                }
                startSubtitle = .automatic   // one video only; the next starts by the rules again
                tracksOwed = nil
                if searchOnline {
                    // Once per video per run, so a search that finds nothing isn't repeated on every replay.
                    autoSearched.insert(item.url)
                    let language = Prefs.string(Prefs.subtitleLanguage)
                    phase = .preparing("Looking for \(Lang.name(language) ?? language) subtitles…")
                    let found = await Self.findSubtitleOnline(for: item, language: language, within: 12)
                    if stale() { return }
                    if let found {
                        library.attachSubtitle(found, toFile: item.url)
                        nowPlaying?.extraSubtitles.append(found)
                        // (The details panel's copy may have taken it up from the library already.)
                        if infoItem?.url == item.url, infoItem?.extraSubtitles.contains(found) == false { infoItem?.extraSubtitles.append(found) }
                        let choice = SubtitleChoice.external(found)
                        if !subtitleChoices.contains(choice) { subtitleChoices.append(choice) }
                        subtitle = choice
                    }
                }
            }

            let settings = EncoderSettings.current()
            plannedSettings = settings
            let profile: DeviceProfile
            switch output {
            case .local: profile = .apple()
            case .cast(let d): profile = .chromecast(model: d.model, capabilities: d.capabilities, settings: settings)
            }
            // Picture subtitles become text through OCR when possible (cached after the first run).
            var cues: [SubtitleCue]?
            if let sub = subtitle, sub.isPicture, Prefs.bool(Prefs.ocrSubtitles), PictureSubtitleOCR.supports(sub, media: item.url) {
                phase = .preparing("Reading subtitles with OCR… (first time only)")
                do {
                    cues = try await PictureSubtitleOCR.shared.cues(
                        for: sub, media: item.url, info: info, preferredLanguage: Prefs.string(Prefs.subtitleLanguage),
                        progress: { [weak self] done, total in
                            Task { @MainActor in
                                guard let self, self.loadToken == token, total > 0, case .preparing = self.phase else { return }
                                self.phase = .preparing("Reading subtitles with OCR… \(done * 100 / total)%")
                            }
                        })
                } catch is CancellationError {
                } catch {
                    // Logged; the subtitle is then drawn into the picture instead, as it is
                    // with OCR turned off.
                    ErrorLog.record("Subtitle OCR", item.url.lastPathComponent, error: error)
                }
                if stale() { return }
            }
            var plan = StreamPlanner.plan(info: info, file: item.url, profile: profile, settings: settings,
                                          audioIndex: audioIndex, subtitle: subtitle, subtitleIsText: cues != nil,
                                          options: options)
            // The title card lives inside an HLS stream, so a file that could be played as it
            // is gets repackaged (copied, not converted) when the card is on.
            let cardWanted = Prefs.bool(Prefs.titleCard) && info.video != nil
            let isLocal = output == .local
            // So is a file with a title of its own (usually its release name): an AirPlay TV
            // reading the file itself could show that while seeking. The stream carries no title.
            let ownTitle = info.embeddedTitle.map { !$0.isEmpty && $0 != item.displayName } ?? false
            if (cardWanted || ownTitle), isLocal, plan.mode == .direct {
                plan.mode = .hls
                if !plan.notes.isEmpty { plan.notes[0] = "Repackaged for streaming, no quality loss" }
            }
            self.plan = plan
            // A stream is cut into pieces by time, and a file whose length can't be read has
            // none to plan.
            if plan.mode == .hls, info.duration <= 0 {
                throw FFmpegError.failed("Driftcast couldn't read how long \(item.url.lastPathComponent) is, so it can't be prepared for \(outputName). The file may be incomplete or damaged.")
            }

            if case .cast(let d) = output { phase = .preparing("Connecting to \(d.name)…") }
            let host = try await target.prepare()
            if stale() { return }

            if let text = plan.textSubtitle, cues == nil {
                phase = .preparing("Loading subtitles…")
                do {
                    cues = try await SubtitleLoader.shared.cues(for: text, media: item.url)
                } catch is CancellationError {
                } catch {
                    // Logged, and shown as off: the menu otherwise went on saying a subtitle
                    // was on with nothing on the screen and nothing to say why.
                    let name: String
                    switch text {
                    case .embedded(let track): name = "track \(track.index)"
                    case .external(let url): name = url.lastPathComponent
                    }
                    ErrorLog.record("Subtitles", "\(name) for \(item.url.lastPathComponent)", error: error)
                    if token == loadToken { subtitle = nil }
                }
                if stale() { return }
            }

            var grid: SegmentGrid?
            if plan.mode == .hls {
                if let v = info.video, plan.isCopyingVideo {
                    phase = .preparing("Indexing keyframes…")
                    let keyframes = try await KeyframeIndex.shared.keyframes(for: item.url, streamIndex: v.index)
                    if stale() { return }
                    grid = .keyframes(keyframes.map { $0 - info.startTime }, duration: info.duration)
                } else {
                    grid = .fixed(duration: info.duration)
                }
            }
            let session = StreamSession(plan: plan, source: item.url, duration: info.duration, grid: grid, cues: cues)
            created = session
            MediaServer.shared.register(session)
            setStreaming(true)

            // Film details and artwork for the card and the Chromecast's screen. They are cached
            // in most cases; a video played the moment it was added waits a few seconds for the
            // lookup its playlist row started, rather than showing a frame instead of the poster.
            var details = await MetadataLookup.shared.cached(for: item.url)
            if details == nil, MetadataLookup.isEnabled, cardWanted || !isLocal {
                phase = .preparing("Looking up details…")
                details = await MetadataLookup.shared.details(for: item.url, within: 6)
                if stale() { return }
            }
            // The year goes only when the poster card, which shows it, is on.
            tvLookedUp = details != nil && cardWanted
            tvLines = item.tvLines(lookedUp: tvLookedUp)
            var artwork: Data?
            if let url = details?.posterURL { artwork = await MetadataLookup.shared.artwork(url, within: 4) }
            if artwork == nil { artwork = await Thumbnailer.shared.poster(for: item.url, duration: info.duration) }
            if stale() { return }
            self.artwork = artwork.flatMap { NSImage(data: $0) }

            // The card and the watched list are for a video starting, not for one loaded again
            // mid-film after a seek or a change of track or screen.
            let first = firstStartOwed == item.id
            if cardWanted, first, isLocal, let grid, let size = plan.outputVideoSize, let v = info.video,
               !(v.isHDR && !plan.isTranscodingVideo),   // an SDR card before HDR would make the TV switch modes twice
               let card = TitleCard.render(poster: artwork, title: item.displayName, details: details, size: size) {
                session.intro = StreamSession.Intro(card: card, size: size, atSegment: grid.index(at: time), hardware: settings.hardware,
                                                    format: TitleCard.Format(plan: plan))
            }

            if plan.mode == .hls {
                phase = .preparing(plan.isTranscodingVideo ? "Starting conversion…" : "Preparing stream…")
                try await session.start(at: time)
                if stale() { return }
            }
            self.session = session

            let path: String
            if plan.mode == .direct {
                path = session.directPath
            } else if isLocal {
                // AVPlayer takes the subtitles as an HLS rendition in the master playlist.
                path = cues != nil ? session.masterPath : session.streamPath
            } else {
                // The Cast player needs the codec attributes; subtitles go as a separate track.
                path = session.castPath
            }
            let url = await MediaServer.shared.url(path: path, host: host)
            if stale() { return }
            streamURL = url
            var subtitleURL: URL?
            if cues != nil {
                subtitleURL = isLocal ? url : await MediaServer.shared.url(path: session.subtitlePath, host: host)
            }
            // The Chromecast's own screen: the film's poster and name.
            var posterURL: URL?
            if !isLocal, let artwork {
                session.poster = artwork
                posterURL = await MediaServer.shared.url(path: session.posterPath, host: host)
            }
            if stale() { return }
            let request = LoadRequest(
                url: url,
                contentType: plan.mode == .direct ? MediaServer.contentType(forExtension: item.url.pathExtension) : "application/x-mpegURL",
                isHLS: plan.mode == .hls,
                title: item.displayName,
                startTime: session.deviceStartTime(forFileTime: time),
                duration: info.duration,
                subtitleURL: subtitleURL,
                subtitleName: session.subtitleName,
                subtitleLanguage: session.subtitleLanguage,
                posterURL: posterURL,
                details: details,
                // A speaker has no screen for the poster: the sound starts at once.
                posterHoldSeconds: cardWanted && first && !isLocal && !plan.isAudioOnly ? TitleCard.seconds : 0,
                startPaused: paused)

            phase = .preparing("Starting playback on \(outputName)…")
            if isLocal && isAirPlaying { airPlayExpectedSince = Date(); airPlayProblem = nil }
            try await target.load(request)
            if stale() { return }
            phase = .buffering
            // A video picked or reached in the playlist, not one reloaded after a seek or a
            // change of screen.
            if first, Prefs.bool(Prefs.watchedList) {
                WatchedList.record(title: item.displayName, filename: item.url.lastPathComponent, path: item.url.path)
            }
            firstStartOwed = nil
            // Also while casting: the window then carries the "connected to" watermark.
            videoWindowRequest += 1
            updateNowPlayingInfo()
        } catch {
            // A load that was overtaken or canceled still made a stream of its own: that is
            // stopped here, or its ffmpeg ran on with nothing left to end it. The one the
            // player now holds belongs to the load that overtook this one and is left alone.
            let stale = token != loadToken || error is CancellationError
            if let created, !stale || created !== session { MediaServer.shared.unregister(created); created.stop() }
            if stale { return }
            if session === created { session = nil }
            streamURL = nil   // the stream is gone; the mirror has nothing to follow
            castReconnecting = false
            // Nothing is being served any more: the Mac may sleep again.
            if session == nil { setStreaming(false) }
            ErrorLog.record("Playback", "\(item.url.lastPathComponent) on \(outputName)", error: error)
            phase = .failed(error.localizedDescription)
        }
    }

    private func teardownSession() {
        if let s = session {
            MediaServer.shared.unregister(s)
            s.stop()
        }
        session = nil
        streamURL = nil
        mirror.stop()
        setStreaming(false)
    }

    // MARK: Status from the device

    private func handle(_ s: TargetStatus, from source: PlaybackOutput) {
        guard source == output else { return }
        if let v = s.volume, v != volume, Date().timeIntervalSince(lastVolumeChange) > 1.5 { volume = v }
        if let m = s.muted, m != deviceMuted, Date().timeIntervalSince(lastVolumeChange) > 1.5 { deviceMuted = m }
        if s.reconnecting {
            if nowPlaying != nil, !castReconnecting { castReconnecting = true }
            return
        }
        if s.reconnected || s.error != nil, castReconnecting { castReconnecting = false }
        if s.reconnected {
            if case .preparing = phase { return }
            // Loaded again where it was, and left paused if it was paused.
            if let item = nowPlaying { start(item, at: position, fresh: false, paused: phase == .paused) }
            return
        }
        guard let session, nowPlaying != nil else { return }
        if case .preparing = phase { return }
        if let e = s.error {
            ErrorLog.record("Playback", "\(nowPlaying?.url.lastPathComponent ?? "?") on \(outputName): \(e)")
            phase = .failed(e)
            setStreaming(false)   // a failed video doesn't keep the Mac awake
            return
        }
        if s.finished {
            itemFinished()
            return
        }
        // A failure stays on show until the video is started again. This Mac's player goes on
        // reporting "paused" twice a second with a failed video, which put "Paused" over the
        // message.
        if case .failed = phase { return }
        if let t = s.time, !isScrubbing {
            position = min(max(0, session.fileTime(forDeviceTime: t)), max(duration, 0))
        }
        // The device reports twice a second; only tell the views when something changed.
        let reported: Phase?
        switch s.state {
        case .playing: reported = .playing
        case .paused: reported = .paused
        case .buffering: reported = .buffering
        case .idle: reported = nil
        }
        if let reported, reported != phase { phase = reported }
        saveProgress(force: false)
    }

    /// With AirPlay the TV downloads the video from this Mac itself. If it has connected but
    /// nothing has asked for the stream, something between them is blocking it (a firewall, a
    /// VPN, or different networks), and the TV just sits on its AirPlay screen.
    private func checkAirPlayReachability() {
        guard output == .local, isAirPlaying, isPlaying, let since = airPlayExpectedSince else {
            if airPlayProblem != nil { airPlayProblem = nil }
            return
        }
        if let last = MediaServer.shared.lastDeviceRequest, last >= since {
            if airPlayProblem != nil { airPlayProblem = nil }
        } else if airPlayProblem == nil, Date().timeIntervalSince(since) > 15 {
            ErrorLog.record("AirPlay", "\(nowPlaying?.url.lastPathComponent ?? "?"): the TV connected but asked this Mac for nothing in 15 seconds")
            airPlayProblem = "The TV connected but can't load the video from this Mac. Check that both are on the same Wi-Fi network, turn off any VPN on this Mac, and allow Driftcast under System Settings > Network > Firewall > Options."
        }
    }

    private func tick() {
        checkAirPlayReachability()
        updateMirror()
        guard let session else { return }
        seekableRange = session.producedRange ?? 0...0
        if isPlaying { updateNowPlayingInfo() }
    }

    /// Keeps the window's silent copy where the TV is, while the window is open to show it.
    private func updateMirror() {
        var casting = remoteDeviceName != nil
        #if DEBUG
        // `-PreviewCastingWatermark Name` shows the casting window with no TV to hand.
        if UserDefaults.standard.string(forKey: "PreviewCastingWatermark") != nil, nowPlaying != nil { casting = true }
        #endif
        // A speaker is sent sound alone: a copy of that has no picture, and the poster stays.
        guard casting, let url = streamURL, info?.video != nil, plan?.isAudioOnly != true, Self.videoWindowIsOpen else {
            mirror.stop()
            return
        }
        let time: Double
        switch output {
        case .local: time = localTarget.player.currentTime().seconds   // AirPlay reports the TV's clock
        case .cast: time = session?.deviceTime(forFileTime: position) ?? position
        }
        guard time.isFinite else { return }
        mirror.follow(url: url, time: time, playing: phase == .playing)
    }

    /// The queue is the playlist as it was when the video was started. Videos added, removed
    /// or moved since are taken up as they happen, so Next, Previous and playing on by itself
    /// follow the list on the screen. A playing video that is in no playlist any more keeps
    /// the queue it had.
    private func syncQueue(with playlists: [Playlist]) {
        // The details panel's video goes the same way: a row taken out of the list isn't
        // kept on show (the panel goes back to the playing video), and one pointed at its
        // file's new place (Locate…) is shown from there.
        if let shown = infoItem {
            if let live = playlists.lazy.flatMap(\.items).first(where: { $0.id == shown.id }) {
                if live != shown { infoItem = live }
            } else if shown.id != nowPlaying?.id {
                infoItem = nowPlaying
            }
        }
        guard let current = nowPlaying,
              let live = playlists.first(where: { $0.items.contains { $0.id == current.id } })?.items,
              let index = live.firstIndex(where: { $0.id == current.id }) else { return }
        if queue != live { queue = live }
        if queueIndex != index { queueIndex = index }
    }

    private func itemFinished() {
        guard let item = nowPlaying else { return }
        position = duration
        library.markWatched(item.url)
        progressSetByHand = nil
        lastProgressSave = Date()
        // Always on since 1.1.3: the switch in Settings was taken out at the user's word
        // (2026-11-20), and a setting left off by an older version no longer stops it.
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            let next = queue[queueIndex]
            start(next, at: resumePoint(for: next), fresh: true)
        } else {
            finishStop()
        }
    }

    private func saveProgress(force: Bool) {
        guard let item = nowPlaying, duration > 0, progressSetByHand != item.url else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) > 5 else { return }
        switch phase {
        case .playing, .paused, .buffering: break
        default: if !force { return }
        }
        lastProgressSave = Date()
        library.updateProgress(for: item.url, position: position, duration: duration, creditsStart: info?.creditsStart)
    }

    // MARK: Transport

    func togglePause() {
        switch phase {
        case .playing, .buffering:
            target.pause()
            phase = .paused
        case .paused:
            target.play()
            phase = .playing
            if output == .local && !isAirPlaying && !Self.videoWindowIsOpen { videoWindowRequest += 1 }
        case .idle, .failed:
            if let item = nowPlaying {
                start(item, at: position, fresh: false)
            } else if let playlist = library.selectedPlaylist {
                // The selected video, which is the one the details panel shows; with none in
                // this playlist, its first.
                let chosen = infoItem.flatMap { shown in playlist.items.first { $0.id == shown.id } } ?? playlist.items.first
                if let chosen { play(chosen, queue: playlist.items) }
            }
        case .preparing:
            break
        }
        updateNowPlayingInfo()
    }

    func stop() {
        saveProgress(force: true)
        finishStop()
    }

    /// Brings the video window back (for its AirPlay button, say) without changing playback.
    func showVideoWindow() { videoWindowRequest += 1 }

    static var videoWindowIsOpen: Bool {
        // A window in the Dock is still open: it isn't brought back, and playback isn't paused for it.
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("video") == true && ($0.isVisible || $0.isMiniaturized) }
    }

    /// The video window was closed. Casting carries on (the window only shows "connected to"),
    /// but a video playing on this Mac pauses rather than going on as sound alone.
    func videoWindowClosed() {
        pauseIfUnseen(windowClosing: true)
    }

    private func pauseIfUnseen(windowClosing: Bool = false) {
        guard output == .local, !isAirPlaying, phase == .playing || phase == .buffering else { return }
        guard windowClosing || !Self.videoWindowIsOpen else { return }
        togglePause()
    }

    private func finishStop() {
        loadToken += 1
        loadTask?.cancel()
        castReconnecting = false
        tracksOwed = nil
        firstStartOwed = nil
        progressSetByHand = nil
        target.stop()
        teardownSession()
        nowPlaying = nil
        info = nil
        plan = nil
        artwork = nil
        phase = .idle
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func seek(to time: Double) {
        // Not before the length is known (a video still opening): every place would be 0.
        guard let item = nowPlaying, duration > 0 else { return }
        let t = min(max(0, time), max(0, duration - 1))
        position = t
        var preparing = false
        if case .preparing = phase { preparing = true }
        // Nothing loaded, or still loading: the load starts again from there. (A seek sent to
        // a player still loading was undone when the load finished at its own place.)
        guard let session, !preparing else {
            start(item, at: t, fresh: false)
            return
        }
        // The poster card sits in the stream where playback began. Played on from before it,
        // the card would come round again mid-film, so that seek gets a stream without one.
        if let card = session.cardFileTime, t < card {
            start(item, at: t, fresh: false)
            return
        }
        // The device has the whole playlist; the server starts converting wherever it reads.
        target.seek(to: session.deviceTime(forFileTime: t))
        updateNowPlayingInfo()
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    // Next and Previous select the video they start in the list and bring it into view
    // (the user's request, 2026-11-20), when the playlist on show has it.
    func next() {
        guard queueIndex + 1 < queue.count else { return }
        queueIndex += 1
        let item = queue[queueIndex]
        start(item, at: resumePoint(for: item), fresh: true)
        library.revealItem(item.id)
    }

    func previous() {
        if position > 8 || queueIndex == 0 {
            seek(to: 0)
            if let item = nowPlaying { library.revealItem(item.id) }
            return
        }
        queueIndex -= 1
        start(queue[queueIndex], at: 0, fresh: true)
        library.revealItem(queue[queueIndex].id)
    }

    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { nowPlaying != nil }

    func setVolume(_ level: Double) {
        volume = min(1, max(0, level))
        lastVolumeChange = Date()
        target.setVolume(volume)
    }

    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }

    /// Mutes the device itself: a Chromecast's own mute, or this Mac's player.
    func setMuted(_ on: Bool) {
        deviceMuted = on
        lastVolumeChange = Date()
        target.setMuted(on)
    }

    /// Mark as Watched and Mark as Unwatched in the list. For the video playing the mark is
    /// the last word: its place isn't saved over it as it plays on, nor when it stops.
    func setWatched(_ watched: Bool, for items: [MediaItem]) {
        for item in items {
            if watched { library.markWatched(item.url) } else { library.clearProgress(item.url) }
            if nowPlaying?.url == item.url { progressSetByHand = item.url }
        }
    }

    // MARK: Tracks and audio options (each restarts the stream at the current position)

    func selectAudio(_ index: Int) {
        guard index != audioIndex else { return }
        audioIndex = index
        reload()
    }

    func selectSubtitle(_ choice: SubtitleChoice?) {
        guard choice != subtitle else { return }
        subtitle = choice
        reload()
    }

    /// Whether the subtitle that is on is a picture one that OCR turns into text: what "Read
    /// Subtitles Again" has to work on. Asked every time a menu is drawn, so it goes by what
    /// is already known and never looks at a disk.
    var canReadSubtitlesAgain: Bool {
        guard let item = nowPlaying, let sub = subtitle, sub.isPicture, Prefs.bool(Prefs.ocrSubtitles) else { return false }
        return PictureSubtitleOCR.supports(sub, media: item.url)
    }

    /// Throws away the text OCR kept for the subtitle that is on and reads its pictures again:
    /// for a reading that came out wrong, or one made by an older Driftcast.
    func readSubtitlesAgain() {
        guard let item = nowPlaying, let sub = subtitle, sub.isPicture else { return }
        Task {
            await PictureSubtitleOCR.shared.forgetReading(of: sub, media: item.url)
            guard nowPlaying?.id == item.id, subtitle == sub else { return }
            reload()
        }
    }

    /// Attaches a subtitle file to a video (the playing one unless another is given) and, when
    /// that video is the one playing, turns it on.
    func addSubtitleFile(_ url: URL, to item: MediaItem? = nil) {
        guard let item = item ?? nowPlaying else { return }
        library.attachSubtitle(url, toFile: item.url)
        if infoItem?.url == item.url, infoItem?.extraSubtitles.contains(url) == false { infoItem?.extraSubtitles.append(url) }
        guard nowPlaying?.url == item.url else { return }
        if nowPlaying?.extraSubtitles.contains(url) == false { nowPlaying?.extraSubtitles.append(url) }
        let choice = SubtitleChoice.external(url)
        if !subtitleChoices.contains(choice) { subtitleChoices.append(choice) }
        selectSubtitle(choice)
    }

    /// Adds the videos or folders and plays the first of them: what Open… chose, and files
    /// opened from the Finder. A video already listed plays from its existing row. False when
    /// none of them is a video.
    @discardableResult
    func open(_ urls: [URL], into playlistID: Playlist.ID? = nil) -> Bool {
        guard let first = library.addToPlay(urls, to: playlistID) else { return false }
        play(first.item, queue: first.queue)
        return true
    }

    /// File > Open… and the toolbar's folder button: choose a video from the Mac and play it.
    func chooseAndOpen(into playlistID: Playlist.ID? = nil) {
        let urls = library.chooseVideos(prompt: "Open", message: "Choose a video to play. Several videos, or a folder, are added to the playlist and the first one plays.")
        guard !urls.isEmpty, !open(urls, into: playlistID) else { return }
        let alert = NSAlert()
        alert.messageText = "No videos were found"
        alert.informativeText = "Choose a video, or a folder with videos in it. MKV, MP4, AVI, MOV and most other formats work."
        alert.runModal()
    }

    /// Asks for a subtitle file for a video (the playing one unless another is given).
    /// The video the Subtitles menu's Add Subtitle File… and Find Subtitles Online… are for:
    /// the one playing, else the one selected in the list (shown in the details panel).
    var subtitleTarget: MediaItem? { nowPlaying ?? infoItem }

    func chooseSubtitleFile(for item: MediaItem? = nil) {
        guard let item = item ?? nowPlaying else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a subtitle file (SRT, ASS, VTT, SUP or IDX)."
        panel.directoryURL = item.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { addSubtitleFile(url, to: item) }
    }

    func setVolumeBoost(_ on: Bool) {
        guard options.volumeBoost != on else { return }
        options.volumeBoost = on
        reload()
    }

    func setDownmix(_ on: Bool) {
        guard options.downmix != on else { return }
        options.downmix = on
        reload()
    }

    /// Debounced so stepping the control several times restarts the stream only once.
    func setAVSync(_ seconds: Double) {
        let v = (seconds * 100).rounded() / 100
        guard v != options.avSyncOffset else { return }
        options.avSyncOffset = v
        syncWork?.cancel()
        syncWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func reload() {
        guard let item = nowPlaying else { return }
        start(item, at: position, fresh: false)
    }

    /// Re-plans the current item (for example after changing conversion settings).
    func restartCurrent() { reload() }

    /// Moves the audio delay by `delta` seconds (menu items), within the same ±2 s range as the slider.
    func nudgeAVSync(_ delta: Double) {
        setAVSync(min(2, max(-2, options.avSyncOffset + delta)))
    }

    /// Opens the playing video's folder in the Finder with the file selected.
    func revealInFinder() {
        guard let item = nowPlaying else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func shutdown() {
        saveProgress(force: true)
        loadTask?.cancel()
        target.stop()
        teardownSession()
        castTarget?.disconnect()
    }

    // MARK: Track defaults

    static func preferredAudio(_ info: MediaInfo) -> MediaInfo.Audio? {
        let pref = Prefs.string(Prefs.audioLanguage)
        if !pref.isEmpty {
            let matching = info.audio.filter { Lang.matches($0.language, pref) }
            if let a = matching.first(where: \.isDefault) ?? matching.first { return a }
        }
        return info.audio.first(where: \.isDefault) ?? info.audio.first
    }

    /// Whether Settings want subtitles on for this audio track: always, or only when the audio
    /// isn't in the preferred subtitle language.
    nonisolated static func subtitlesWanted(audio: MediaInfo.Audio?) -> Bool {
        let pref = Prefs.string(Prefs.subtitleLanguage)
        guard !pref.isEmpty else { return false }
        switch SubtitleAuto.current {
        case .never: return false
        case .foreign: return !Lang.matches(audio?.language, pref)
        case .always: return true
        }
    }

    nonisolated static func preferredSubtitle(_ choices: [SubtitleChoice], audio: MediaInfo.Audio?) -> SubtitleChoice? {
        // Nothing comes on by itself unless Settings ask for captions (the user's wish: "Turn On", not "Turn Off").
        guard subtitlesWanted(audio: audio) else { return nil }
        let pref = Prefs.string(Prefs.subtitleLanguage)
        let full = choices.filter { Lang.matches($0.language, pref) && !$0.isForced }
        if let c = full.first(where: { !$0.isPicture }) ?? full.first { return c }
        // Failing a full track, a forced one (signs and foreign lines) in the language is better than nothing.
        return choices.first { $0.isForced && ($0.language == nil || Lang.matches($0.language, pref)) }
    }

    /// True when the rule wants subtitles, the video has none in the language, and Settings
    /// allow OpenSubtitles to be asked for them (which needs a key).
    nonisolated static func shouldSearchOnline(choices: [SubtitleChoice], audio: MediaInfo.Audio?) -> Bool {
        guard Prefs.bool(Prefs.autoSearchSubtitles), OpenSubtitlesClient.hasKey, subtitlesWanted(audio: audio) else { return false }
        let pref = Prefs.string(Prefs.subtitleLanguage)
        return !choices.contains { Lang.matches($0.language, pref) && !$0.isForced }
    }

    /// Asks OpenSubtitles for the video's subtitles in `language` (the file's fingerprint first,
    /// then its title, with the season and episode for a show) and downloads the best match.
    /// Nil when nothing fits, the key is missing, or it takes longer than `seconds`.
    nonisolated static func findSubtitleOnline(for item: MediaItem, language: String, within seconds: Double) async -> URL? {
        await Deadline.first(within: seconds) {
            guard let client = try? OpenSubtitlesClient.fromSettings() else { return nil }
            do {
                let found = try await OpenSubtitlesClient.searchVideo(item, language: language)
                // Listed best first: made from this file, then for its release, then most downloaded.
                // One that only covers the foreign-language lines isn't the film's subtitles.
                guard let best = found.first(where: { !$0.foreignPartsOnly }) else { return nil }
                return try await client.download(best, for: item.url)
            } catch {
                return nil
            }
        }
    }

    // MARK: Media keys and Now Playing

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.phase == .paused { self?.togglePause() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePause() } }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    /// A video was given another name in the list. When it is the one playing, the bar, the
    /// video window's title and the TV's panel take the new name now. A Chromecast keeps the
    /// name it was sent until the video is next started.
    func nameChanged(for url: URL) {
        guard let item = nowPlaying, item.url == url else { return }
        objectWillChange.send()
        tvLines = item.tvLines(lookedUp: tvLookedUp)
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let item = nowPlaying else { return }
        let lines = tvLines ?? item.tvLines(lookedUp: false)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: lines.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        // The second line under the title on the TV's panel (and in Control Center).
        if let subtitle = lines.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = phase == .paused ? .paused : (isPlaying ? .playing : .stopped)
    }
}

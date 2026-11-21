import Foundation
import Network

enum CastError: LocalizedError {
    case timeout
    case notConnected
    case launchFailed
    case loadFailed(String)
    case connection(String)
    /// The connection went while this Mac was asleep (see CastTarget.channelLost).
    case asleep
    /// The Chromecast was told to play but asked this Mac for nothing.
    case unreachable
    /// The receiver closed, or another sender stopped or replaced our video (the device's name).
    case stoppedElsewhere(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The Chromecast didn't respond in time. Check that it is on and on the same network, and that Driftcast is allowed to find devices on the local network (System Settings > Privacy & Security > Local Network)."
        case .notConnected: return "Not connected to the Chromecast."
        case .launchFailed: return "The Chromecast couldn't start its media player."
        case .loadFailed(let s): return "The Chromecast couldn't play this stream (\(s))."
        case .connection(let s): return "Lost connection to the Chromecast: \(s)"
        case .asleep: return "Lost connection to the Chromecast while this Mac was asleep."
        case .unreachable: return "The Chromecast couldn't load the video from this Mac. Check that both are on the same Wi-Fi network, turn off any VPN on this Mac, and allow Driftcast under System Settings > Network > Firewall > Options."
        case .stoppedElsewhere(let name): return "Playback on \(name) was stopped from another device."
        }
    }
}

/// Drives a Chromecast's Default Media Receiver over the Cast v2 protocol.
///
/// Sequence: CONNECT to receiver-0, LAUNCH app CC1AD845, read its transportId from
/// RECEIVER_STATUS, CONNECT to the transport, then LOAD / PLAY / PAUSE / SEEK on the media
/// namespace. A PING every 5 s keeps the session alive.
///
/// The receiver is shared: every sender connected to it hears every status. Only the receiver
/// session this target joined or launched, and the media session its own LOAD started, are
/// taken as ours; when another sender stops or replaces them, that is reported once.
@MainActor
final class CastTarget: PlaybackTarget {
    static let defaultReceiverAppID = "CC1AD845"

    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    /// Thrown when a dropped connection is remade but the receiver session that was playing has
    /// ended (or another sender has started the player afresh): there is nothing to rejoin.
    private struct ReceiverGone: Error {}

    /// A moment by the wall clock and by the system's awake time. The wall clock runs on while
    /// the Mac sleeps and the awake time doesn't, so the difference between them since a tick is
    /// the time spent asleep; a timer that only ran late (App Nap, a menu held open) adds nothing.
    private struct Tick {
        var wall = Date()
        var awake = ProcessInfo.processInfo.systemUptime
        var sleptSince: Double { Date().timeIntervalSince(wall) - (ProcessInfo.processInfo.systemUptime - awake) }
    }

    /// Asleep for longer than this, the link has been silent past the 25 seconds the heartbeat
    /// allows, and has probably gone.
    private static let sleepGap: Double = 30

    let device: CastDeviceInfo
    var onStatus: ((TargetStatus) -> Void)?

    /// Makes the connection: a CastChannel to the device, or a stand-in in the harness.
    private let makeLink: (NWEndpoint) -> any CastLink
    private var channel: (any CastLink)?
    private var transportID: String?
    private var appSessionID: String?
    /// The media session our own LOAD started. Statuses of any other session are someone else's,
    /// and nil means nothing of ours is loaded (before a LOAD is answered, after Stop).
    private var mediaSessionID: Int?
    /// Set when the answer to a LOAD didn't name its session: the next status does.
    private var adoptNextSession = false
    private var nextRequestID = 1
    private struct Pending {
        var destination: String
        var continuation: CheckedContinuation<[String: Any], Error>
    }
    private var pending: [Int: Pending] = [:]
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private var lastHeard = Date()
    /// When the heartbeat timer last ran (see `Tick`).
    private var lastTick = Tick()
    /// When the heartbeat timer found that this Mac had been asleep.
    private var wokeAt: Date?
    private var localHost: String?
    private var reconnecting = false
    /// The connection being made; everyone who needs one waits for it rather than making another.
    private var connecting: Task<Void, Error>?
    /// Set by `disconnect()`: the controller has let go of this target, nothing more is reported,
    /// and nothing is launched. A connection being made at that moment still finishes, so that
    /// the session it reached on the TV can be stopped.
    private var leaving = false
    /// Counts LOADs and Stops, so the answer to a LOAD that comes after Stop (or after a newer
    /// LOAD) is recognized.
    private var loadGeneration = 0
    /// The `loadGeneration` that the last Stop set.
    private var stoppedGeneration = -1

    init(device: CastDeviceInfo, link: @escaping (NWEndpoint) -> any CastLink = { CastChannel(endpoint: $0) }) {
        self.device = device
        self.makeLink = link
    }

    // MARK: Connection

    func prepare() async throws -> String {
        try await ensureConnected()
        return localHost ?? NetworkUtil.primaryIPv4() ?? "127.0.0.1"
    }

    /// Connects and joins the media receiver, launching it if it isn't running. A load, a skip
    /// and a track change can all ask at once while "Connecting to X…" is up; each asking on its
    /// own opened a second socket and sent a second LAUNCH, which can restart the player. So one
    /// connection is made at a time, and a caller that comes meanwhile waits for it and makes its
    /// own only if that one didn't get there. `rejoining` is for the reconnect loop (see
    /// `joinReceiver`).
    private func ensureConnected(rejoining expected: String? = nil) async throws {
        while let running = connecting { _ = try? await running.value }
        if leaving && expected == nil { throw CancellationError() }
        if channel != nil, transportID != nil { return }
        let task = Task { @MainActor in
            defer { self.connecting = nil }
            try await self.connect(rejoining: expected)
        }
        connecting = task
        try await task.value
    }

    private func connect(rejoining expected: String?) async throws {
        do {
            if channel == nil { try await openChannel() }
            if transportID == nil { try await joinReceiver(rejoining: expected) }
        } catch {
            if leaving { endSession() }
            throw error
        }
        if leaving {
            endSession()
            throw CancellationError()
        }
    }

    private func openChannel() async throws {
        let ch = makeLink(device.endpoint)
        let once = ResumeOnce()
        let early = EarlyFailure()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ch.onEvent = { [weak self, weak ch] event in
                Task { @MainActor in
                    switch event {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case .failed(let reason):
                        if once.claim() {
                            cont.resume(throwing: CastError.connection(reason))
                        } else if let ch, let self, self.channel === ch {
                            self.channelLost(reason, on: ch)
                        } else {
                            early.reason = reason   // failed right after it was ready, before it was taken up
                        }
                    }
                }
            }
            // Only the current connection is listened to: an old one's last words belong to a
            // session that is over.
            ch.onMessage = { [weak self, weak ch] msg in
                Task { @MainActor in
                    guard let self, let ch, self.channel === ch else { return }
                    self.handle(msg)
                }
            }
            ch.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if once.claim() { ch.close(); cont.resume(throwing: CastError.timeout) }
            }
        }
        if let reason = early.reason {
            ch.close()
            throw CastError.connection(reason)
        }
        channel = ch
        localHost = ch.localIPv4
        lastHeard = Date()
        lastTick = Tick()
        wokeAt = nil
        ch.send(namespace: NS.connection, destination: "receiver-0", payload: ["type": "CONNECT", "origin": [String: Any]()])
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
    }

    private func heartbeat() {
        guard let channel else { return }
        if lastTick.sleptSince > Self.sleepGap {
            // This Mac has been asleep. The silence while it slept says nothing about the device,
            // so the link has a fresh 25 seconds to answer this PING. If it has gone, it isn't
            // remade (see channelLost).
            wokeAt = Date()
            lastHeard = Date()
        }
        lastTick = Tick()
        if Date().timeIntervalSince(lastHeard) > 25 { channelLost("no heartbeat", on: channel); return }
        channel.send(namespace: NS.heartbeat, destination: "receiver-0", payload: ["type": "PING"])
    }

    /// Joins the Default Media Receiver if it is running, and otherwise launches it.
    ///
    /// `expected` is set when a dropped connection is being remade: only that receiver session,
    /// the one that was playing, is joined, and nothing is launched. If it has ended (stopped on
    /// the TV, closed after idling, or replaced by another app or another sender), launching the
    /// player again would wake the TV or interrupt what is on it now (ReceiverGone).
    private func joinReceiver(rejoining expected: String?) async throws {
        // Left before anything was launched: there is nothing on the TV to stop.
        if leaving && expected == nil { throw CancellationError() }
        var app = Self.mediaReceiver(in: try await request(NS.receiver, "receiver-0", ["type": "GET_STATUS"]))
        if let expected {
            guard let found = app, found.session == expected else { throw ReceiverGone() }
        } else if app == nil {
            guard !leaving else { throw CancellationError() }
            app = Self.mediaReceiver(in: try await request(NS.receiver, "receiver-0", ["type": "LAUNCH", "appId": Self.defaultReceiverAppID], timeout: 20))
        }
        // The answer to LAUNCH can come before the player has a transport. A target being left
        // goes on asking too, to learn which session to stop.
        var tries = 0
        while app == nil && tries < 12 {
            try await Task.sleep(nanoseconds: 500_000_000)
            app = Self.mediaReceiver(in: try await request(NS.receiver, "receiver-0", ["type": "GET_STATUS"]))
            tries += 1
        }
        guard let app else { throw CastError.launchFailed }
        appSessionID = app.session
        guard !leaving else { throw CancellationError() }
        transportID = app.transport
        channel?.send(namespace: NS.connection, destination: app.transport, payload: ["type": "CONNECT", "origin": [String: Any]()])
    }

    /// Our player in a RECEIVER_STATUS: its transport and session, or nil if it isn't running.
    private static func mediaReceiver(in msg: [String: Any]) -> (transport: String, session: String?)? {
        let status = msg["status"] as? [String: Any] ?? [:]
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == defaultReceiverAppID }),
              let t = app["transportId"] as? String else { return nil }
        return (t, app["sessionId"] as? String)
    }

    private(set) var volumeLevel: Double?

    private func request(_ ns: String, _ destination: String, _ payload: [String: Any], timeout: Double = 10) async throws -> [String: Any] {
        guard let channel else { throw CastError.notConnected }
        let id = nextRequestID
        nextRequestID += 1
        var p = payload
        p["requestId"] = id
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = Pending(destination: destination, continuation: cont)
            channel.send(namespace: ns, destination: destination, payload: p)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let p = self?.pending.removeValue(forKey: id) { p.continuation.resume(throwing: CastError.timeout) }
            }
        }
    }

    /// Fire-and-forget command (the device still wants a requestId).
    private func command(_ ns: String, _ destination: String, _ payload: [String: Any]) {
        var p = payload
        p["requestId"] = nextRequestID
        nextRequestID += 1
        channel?.send(namespace: ns, destination: destination, payload: p)
    }

    private func channelLost(_ reason: String, on lost: any CastLink) {
        // An old connection's late news (a newer one has been made since).
        guard lost === channel else { return }
        let session = transportID != nil ? appSessionID : nil
        let media = mediaSessionID
        // Lost while this Mac slept, or found dead within the 25 seconds (and a tick) it was
        // given on waking.
        let asleep = lastTick.sleptSince > Self.sleepGap || wokeAt.map { Date().timeIntervalSince($0) < 35 } == true
        reset()
        // A connection being made reports to whoever waits for it, the reconnect loop tries
        // again, and a target being left has nobody to tell.
        if leaving || reconnecting || connecting != nil { return }
        guard let session else {
            onStatus?(TargetStatus(state: .idle, error: CastError.connection(reason).localizedDescription))
            return
        }
        if asleep {
            // The connection went because this Mac slept, maybe for hours, and the TV may since
            // have been turned off or put to other use. Starting the video again by itself would
            // turn the TV on to play it, so it waits for Play.
            onStatus?(TargetStatus(state: .idle, error: CastError.asleep.localizedDescription))
            return
        }
        reconnect(to: session, media: media, after: reason)
    }

    /// Wi-Fi blips are common: the connection is remade for a few seconds before giving up. Only
    /// the receiver session that was playing is rejoined; nothing is launched (see joinReceiver).
    /// The controller loads the video again on `reconnected`.
    private func reconnect(to session: String, media: Int?, after reason: String) {
        let failure = CastError.connection(reason).localizedDescription
        let generation = loadGeneration
        reconnecting = true
        onStatus?(TargetStatus(state: .idle, reconnecting: true))
        // Holds the target, so that one left meanwhile still makes its one attempt to stop the TV.
        Task { @MainActor in
            defer { self.reconnecting = false }
            var gone = false
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                if self.channel != nil, self.transportID != nil {
                    // A new video connected in the meantime and is in charge now.
                    if self.leaving { self.endSession() }
                    return
                }
                do {
                    try await self.ensureConnected(rejoining: session)
                } catch is ReceiverGone {
                    gone = true
                } catch {
                    if self.leaving { return }   // its one attempt is made
                    continue
                }
                if gone { break }
                if self.leaving { self.endSession(); return }
                // Stop pressed while the connection was down reaches the TV now.
                if self.loadGeneration != generation, self.stoppedGeneration == self.loadGeneration,
                   let media, let t = self.transportID {
                    self.command(NS.media, t, ["type": "STOP", "mediaSessionId": media])
                }
                self.onStatus?(TargetStatus(state: .idle, reconnected: true))
                return
            }
            self.onStatus?(TargetStatus(state: .idle, error: failure))
        }
    }

    private func reset() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        pollTimer?.invalidate(); pollTimer = nil
        channel?.close()
        channel = nil
        transportID = nil
        appSessionID = nil
        mediaSessionID = nil
        adoptNextSession = false
        holdUntil = nil
        wokeAt = nil
        let waiting = pending
        pending = [:]
        for (_, p) in waiting { p.continuation.resume(throwing: CastError.notConnected) }
    }

    // MARK: Incoming

    private func handle(_ msg: CastProto.Message) {
        lastHeard = Date()
        guard let payload = msg.payload, let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""

        if msg.namespace == NS.heartbeat {
            if type == "PING" { channel?.send(namespace: NS.heartbeat, destination: msg.source, payload: ["type": "PONG"]) }
            return
        }
        if msg.namespace == NS.connection, type == "CLOSE" {
            if msg.source == transportID { receiverAppClosed() }
            return
        }
        if let rid = json["requestId"] as? Int, rid != 0, let p = pending.removeValue(forKey: rid) {
            p.continuation.resume(returning: json)
        }
        switch type {
        case "RECEIVER_STATUS":
            // The device's own volume is here. MEDIA_STATUS has a volume too, but that is the
            // stream's (1.0 unless a sender changes it), and taking it for the TV's sent the
            // slider to full and Volume Down to 95%.
            let status = json["status"] as? [String: Any] ?? [:]
            if let vol = status["volume"] as? [String: Any], let level = vol["level"] as? Double {
                volumeLevel = level
                // Only the volume: this says nothing about what is playing.
                onStatus?(TargetStatus(state: .idle, volume: level, muted: vol["muted"] as? Bool))
            }
            // Our player has closed, or another sender has started it afresh (a new session).
            if transportID != nil, Self.mediaReceiver(in: json).map({ $0.session == appSessionID }) != true {
                receiverAppClosed()
            }
        case "MEDIA_STATUS":
            applyMediaStatus(json)
        default:
            break
        }
    }

    private func applyMediaStatus(_ json: [String: Any]) {
        guard let entries = json["status"] as? [[String: Any]] else { return }
        if mediaSessionID == nil, adoptNextSession, let id = entries.first?["mediaSessionId"] as? Int {
            mediaSessionID = id
            adoptNextSession = false
        }
        guard let ours = mediaSessionID else { return }
        guard let s = entries.first(where: { ($0["mediaSessionId"] as? Int) == ours }) else {
            // Another sender's video has replaced ours (a Home Assistant announcement, a phone,
            // a second Mac using the same player). Taking its statuses for ours saved its
            // position as this film's, sent Pause and Seek to it, and on its end marked our
            // film watched and loaded our next video over it.
            if entries.contains(where: { ($0["playerState"] as? String ?? "IDLE") != "IDLE" }) {
                endOwnMedia()
                onStatus?(TargetStatus(state: .idle, error: CastError.stoppedElsewhere(device.name).localizedDescription))
            }
            return
        }
        var status = TargetStatus()
        switch s["playerState"] as? String {
        case "PLAYING": status.state = .playing
        case "PAUSED": status.state = holdUntil.map { $0 > Date() } == true ? .buffering : .paused
        case "BUFFERING", "LOADING": status.state = .buffering
        default: status.state = .idle
        }
        status.time = s["currentTime"] as? Double
        if status.state == .idle, let reason = s["idleReason"] as? String {
            switch reason {
            case "FINISHED": status.finished = true
            case "ERROR":
                let code = (s["extendedStatus"] as? [String: Any])?["detailedErrorCode"] ?? ""
                status.error = "The Chromecast stopped with a playback error \(code)".trimmingCharacters(in: .whitespaces)
            case "CANCELLED", "INTERRUPTED":
                // Stopped by voice ("Hey Google, stop") or from another sender, or replaced by
                // another sender's LOAD. Our own Stop and LOAD let go of the session first, so
                // these are never ours.
                status.error = CastError.stoppedElsewhere(device.name).localizedDescription
            default: break
            }
            // The session is over. Each poll would repeat its last status, so it is reported once.
            endOwnMedia()
        }
        onStatus?(status)
    }

    /// Nothing more about our media session is reported, and its statuses are no longer asked for.
    private func endOwnMedia() {
        mediaSessionID = nil
        adoptNextSession = false
        holdUntil = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func receiverAppClosed() {
        let closedTransport = transportID
        let wasPlaying = mediaSessionID != nil
        transportID = nil
        appSessionID = nil
        endOwnMedia()
        // A LOAD sent to the player that closed would never be answered.
        for (id, p) in pending where p.destination == closedTransport {
            pending[id] = nil
            p.continuation.resume(throwing: CastError.stoppedElsewhere(device.name))
        }
        if wasPlaying {
            onStatus?(TargetStatus(state: .idle, error: CastError.stoppedElsewhere(device.name).localizedDescription))
        }
    }

    // MARK: Control

    func load(_ r: LoadRequest) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        try await ensureConnected()
        // Stop was pressed, or another video started, while the connection was being made.
        guard generation == loadGeneration else { throw CancellationError() }
        guard let transportID else { throw CastError.notConnected }
        mediaSessionID = nil
        adoptNextSession = false
        holdUntil = nil

        // What the TV shows while loading and paused: a film's title, year and director, or an
        // episode's show, number and name, with the poster.
        var metadata: [String: Any]
        if let d = r.details, d.isEpisode {
            metadata = ["metadataType": 2, "seriesTitle": d.showTitle ?? d.title, "title": d.episodeTitle ?? r.title]
            if let season = d.season { metadata["season"] = season }
            if let episode = d.episode { metadata["episode"] = episode }
            if let date = d.airDate, date.count == 10 { metadata["originalAirdate"] = date }
        } else if let d = r.details {
            metadata = ["metadataType": 1, "title": d.title]
            var subtitle: [String] = []
            if let year = d.year { subtitle.append(String(year)) }
            if let director = d.directors.first { subtitle.append("Directed by \(director)") }
            if !subtitle.isEmpty { metadata["subtitle"] = subtitle.joined(separator: " · ") }
            if let studio = d.network { metadata["studio"] = studio }
        } else {
            metadata = ["metadataType": 0, "title": r.title]
        }
        if let poster = r.posterURL { metadata["images"] = [["url": poster.absoluteString]] }
        var media: [String: Any] = [
            "contentId": r.url.absoluteString,
            "contentUrl": r.url.absoluteString,
            "contentType": r.contentType,
            "streamType": "BUFFERED",
            "metadata": metadata,
        ]
        if r.duration > 0 { media["duration"] = r.duration }
        if r.isHLS {
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
        }
        // With a hold, the receiver stays on its poster-and-title screen (its paused state)
        // for a moment, then PLAY starts the video. A video loaded paused stays there.
        let hold = r.startPaused ? 0 : r.posterHoldSeconds
        var message: [String: Any] = ["type": "LOAD", "media": media, "autoplay": hold <= 0 && !r.startPaused, "currentTime": r.startTime]
        if let sub = r.subtitleURL {
            media["tracks"] = [[
                "trackId": 1, "type": "TEXT", "subtype": "SUBTITLES",
                "trackContentId": sub.absoluteString, "trackContentType": "text/vtt",
                "name": r.subtitleName ?? "Subtitles", "language": r.subtitleLanguage ?? "en",
            ]]
            media["textTrackStyle"] = Self.textTrackStyle(scale: SubtitleSize.current)
            message["media"] = media
            message["activeTrackIds"] = [1]
        }

        let sentAt = Date()
        let resp: [String: Any]
        do {
            resp = try await request(NS.media, transportID, message, timeout: 45)
        } catch CastError.timeout where Self.nothingFetched(since: sentAt) {
            throw CastError.unreachable
        }
        let type = resp["type"] as? String ?? ""
        guard type == "MEDIA_STATUS" else {
            if generation != loadGeneration { throw CancellationError() }
            // The player gives up when it can't fetch the stream. Having asked this Mac for
            // nothing at all (not even the poster), it never reached it: usually the firewall.
            if type == "LOAD_FAILED", Self.nothingFetched(since: sentAt) { throw CastError.unreachable }
            let detail = (resp["detailedErrorCode"] as? Int).map { "error \($0)" } ?? (resp["reason"] as? String) ?? type
            throw CastError.loadFailed(detail)
        }
        // The answer to our LOAD names the media session it started: ours from now on.
        let session = (resp["status"] as? [[String: Any]])?.first?["mediaSessionId"] as? Int
        guard generation == loadGeneration else {
            // Stop was pressed while the TV was loading, before there was a session to send
            // STOP for, and the TV would go on to play a stream that is no longer served. It
            // gets that STOP now. A newer LOAD replaces this one by itself.
            if stoppedGeneration == loadGeneration, let session {
                command(NS.media, transportID, ["type": "STOP", "mediaSessionId": session])
            }
            throw CancellationError()
        }
        mediaSessionID = session
        adoptNextSession = session == nil
        startPolling()
        if hold > 0 {
            let until = Date().addingTimeInterval(hold)
            holdUntil = until
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                // Anything that ends this media session (Stop, a new LOAD, a lost connection)
                // clears the hold first.
                guard let self, self.holdUntil == until else { return }
                self.holdUntil = nil
                self.play()
            }
        }
    }

    /// While the poster is being shown on purpose, the receiver's "paused" is really "starting".
    private var holdUntil: Date?

    /// True when no device has asked this Mac's server for anything since `date`.
    private static func nothingFetched(since date: Date) -> Bool {
        MediaServer.shared.lastDeviceRequest.map { $0 < date } ?? true
    }

    /// Asks for the status of every media session, as pychromecast does, not just ours: when
    /// another sender's video has replaced ours, the answer shows it (see applyMediaStatus).
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.transportID else { return }
                self.command(NS.media, t, ["type": "GET_STATUS"])
            }
        }
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) {
        guard let t = transportID, let id = mediaSessionID else { return }
        var p = extra
        p["type"] = type
        p["mediaSessionId"] = id
        command(NS.media, t, p)
    }

    /// White text with a black outline at `scale` times the receiver's normal size.
    static func textTrackStyle(scale: Double) -> [String: Any] {
        [
            "foregroundColor": "#FFFFFFFF", "backgroundColor": "#00000000",
            "edgeType": "OUTLINE", "edgeColor": "#000000FF",
            "fontScale": SubtitleSize.normalized(scale), "fontFamily": "Droid Sans",
        ]
    }

    /// The receiver restyles the text track it is showing without reloading the video.
    func setSubtitleScale(_ scale: Double) {
        mediaCommand("EDIT_TRACKS_INFO", ["textTrackStyle": Self.textTrackStyle(scale: scale)])
    }

    func play() { mediaCommand("PLAY") }
    func pause() { mediaCommand("PAUSE") }
    func seek(to seconds: Double) { mediaCommand("SEEK", ["currentTime": max(0, seconds)]) }

    func stop() {
        // A LOAD still on its way is answered after this, naming the session this STOP can't;
        // load() stops that session then.
        loadGeneration += 1
        stoppedGeneration = loadGeneration
        mediaCommand("STOP")
        endOwnMedia()
    }

    /// The device's own volume (SET_VOLUME on the receiver, not the stream's).
    func setVolume(_ level: Double) {
        guard channel != nil else { return }
        command(NS.receiver, "receiver-0", ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level))]])
    }

    /// The device's own mute; SET_VOLUME carries either a level or the mute, not both.
    func setMuted(_ muted: Bool) {
        guard channel != nil else { return }
        command(NS.receiver, "receiver-0", ["type": "SET_VOLUME", "volume": ["muted": muted]])
    }

    /// Stops the receiver app on the TV and closes the connection.
    ///
    /// The controller lets go of the target straight after. A connection being made or remade
    /// at that moment is finished first, launching nothing, and then stops whatever it reached:
    /// cut off midway, a LAUNCH already sent left the player up on the TV with nobody to stop
    /// it, and the reconnect loop rejoined it and left it there.
    func disconnect() {
        leaving = true
        onStatus = nil
        if connecting != nil || reconnecting { return }
        endSession()
    }

    private func endSession() {
        if let sid = appSessionID { command(NS.receiver, "receiver-0", ["type": "STOP", "sessionId": sid]) }
        if let t = transportID { channel?.send(namespace: NS.connection, destination: t, payload: ["type": "CLOSE"]) }
        reset()
    }
}

/// A connection's failure that came after it was ready but before CastTarget took it up.
/// Written and read on the main actor only.
private final class EarlyFailure: @unchecked Sendable {
    var reason: String?
}

/// Lets exactly one of several racing callbacks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

import Foundation
import Network

// Harness checks for Chromecast: framing, status handling, connecting.
// Uses check(_:_:), spin, await_ and fetch from Helpers.swift, and the global mediaDir (the
// test media folder, from the command line) that harness.swift defines.
func castTests() {
    castFramingTests()
    MainActor.assumeIsolated { castTargetTests() }
}

// MARK: Framing

private func castFramingTests() {
    func decodes(_ bytes: [UInt8]) -> CastProto.Message? { CastProto.decode(Data(bytes)) }

    // A string field (key 0x12 = field 2, wire type 2) whose length varint is 2^64 - 1, then one
    // just under 2^63: the first trapped converting to Int, the second adding to the position.
    check(decodes([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]) == nil,
          "Cast frame with a 2^64 - 1 field length is refused, not a crash")
    check(decodes([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) == nil,
          "Cast frame with a field length just under 2^63 is refused, not a crash")
    check(decodes([0x12, 0x05, 0x61, 0x62]) == nil, "Cast frame whose field runs past the end is refused")
    check(decodes([0x12]) == nil, "Cast frame cut off inside a varint is refused")
    check(decodes([0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]) == nil,
          "Cast frame with an 11-byte varint is refused")
    check(decodes([0x12, 0x02, 0x61, 0x62])?.source == "ab", "Cast field ending exactly at the end of the frame is read")
    check(decodes([0x12, 0x00])?.source == "", "Cast empty string field is read")
    // Unknown fields of every wire type are stepped over: a varint (field 15), a fixed64
    // (field 16) and a fixed32 (field 17) before the payload.
    var mixed: [UInt8] = [0x78, 0x96, 0x01]
    mixed += [0x81, 0x01] + [UInt8](repeating: 0, count: 8)
    mixed += [0x8D, 0x01] + [UInt8](repeating: 0, count: 4)
    mixed += [0x32, 0x02, 0x7B, 0x7D]
    check(decodes(mixed)?.payload == "{}", "Cast unknown varint, fixed64 and fixed32 fields are skipped")
    let long = String(repeating: "x", count: 300)
    let round = CastProto.decode(CastProto.encode(source: "a", destination: "b", namespace: "c", payload: long))
    check(round?.payload == long && round?.namespace == "c", "Cast field longer than 127 bytes (two-byte length) round trips")
}

// MARK: A pretend Chromecast

private enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

/// Answers what CastTarget sends the way a Default Media Receiver does (Google's Cast v2
/// documentation and pychromecast), records everything, and lets a test hold an answer back,
/// drop the connection, or play another sender's part. Nothing goes on the network.
private final class FakeReceiver {
    var appRunning = false
    var appSession = "session-1"
    let transport = "transport-1"
    var mediaSession = 0          // the current media session's id; 0 when none
    var playerState = "IDLE"
    var idleReason: String?
    var volume = 0.3
    var muted = false
    var loadReply = "MEDIA_STATUS"
    var holdReady = false
    var heldReady: (() -> Void)?
    var holdLaunch = false
    var heldLaunch: (() -> Void)?
    var holdLoad = false
    var heldLoad: (() -> Void)?
    var links: [FakeLink] = []
    var sent: [(ns: String, dest: String, payload: [String: Any])] = []

    func makeLink(_ endpoint: NWEndpoint) -> any CastLink {
        let link = FakeLink(self)
        links.append(link)
        return link
    }
    var link: FakeLink { links.last! }

    func sent(_ type: String, ns: String? = nil) -> [[String: Any]] {
        sent.filter { $0.payload["type"] as? String == type && (ns == nil || $0.ns == ns) }.map(\.payload)
    }

    func receiverStatus(_ requestId: Int = 0) -> [String: Any] {
        var status: [String: Any] = ["volume": ["level": volume, "muted": muted, "controlType": "attenuation", "stepInterval": 0.05]]
        if appRunning {
            status["applications"] = [["appId": "CC1AD845", "displayName": "Default Media Receiver",
                                       "sessionId": appSession, "transportId": transport]]
        }
        return ["type": "RECEIVER_STATUS", "requestId": requestId, "status": status]
    }

    func mediaStatus(_ requestId: Int = 0) -> [String: Any] {
        var entries: [[String: Any]] = []
        if mediaSession != 0 {
            // The stream's own volume, which is not the TV's.
            var e: [String: Any] = ["mediaSessionId": mediaSession, "playerState": playerState, "currentTime": 12.5,
                                    "playbackRate": 1, "volume": ["level": 1.0, "muted": false]]
            if let idleReason { e["idleReason"] = idleReason }
            entries.append(e)
        }
        return ["type": "MEDIA_STATUS", "requestId": requestId, "status": entries]
    }

    func receive(_ ns: String, _ dest: String, _ p: [String: Any], on link: FakeLink) {
        sent.append((ns, dest, p))
        let rid = p["requestId"] as? Int ?? 0
        switch (ns, p["type"] as? String ?? "") {
        case (CastNS.heartbeat, "PING"):
            link.deliver(CastNS.heartbeat, "receiver-0", ["type": "PONG"])
        case (CastNS.receiver, "GET_STATUS"):
            link.deliver(CastNS.receiver, "receiver-0", receiverStatus(rid))
        case (CastNS.receiver, "LAUNCH"):
            let answer = { [self] in
                appRunning = true
                link.deliver(CastNS.receiver, "receiver-0", receiverStatus(rid))
            }
            if holdLaunch { heldLaunch = answer } else { answer() }
        case (CastNS.receiver, "STOP"):
            appRunning = false
            mediaSession = 0
        case (CastNS.receiver, "SET_VOLUME"):
            let v = p["volume"] as? [String: Any] ?? [:]
            if let level = v["level"] as? Double { volume = level }
            if let m = v["muted"] as? Bool { muted = m }
            link.deliver(CastNS.receiver, "receiver-0", receiverStatus())
        case (CastNS.media, "LOAD"):
            let answer = { [self] in
                guard loadReply == "MEDIA_STATUS" else {
                    link.deliver(CastNS.media, transport, ["type": loadReply, "requestId": rid])
                    return
                }
                mediaSession += 1
                playerState = p["autoplay"] as? Bool == false ? "PAUSED" : "PLAYING"
                idleReason = nil
                link.deliver(CastNS.media, transport, mediaStatus(rid))
            }
            if holdLoad { heldLoad = answer } else { answer() }
        case (CastNS.media, "GET_STATUS"):
            link.deliver(CastNS.media, transport, mediaStatus(rid))
        case (CastNS.media, "STOP"):
            if p["mediaSessionId"] as? Int == mediaSession { playerState = "IDLE"; idleReason = "CANCELLED" }
        case (CastNS.media, "PLAY"):
            if p["mediaSessionId"] as? Int == mediaSession { playerState = "PLAYING" }
        case (CastNS.media, "PAUSE"):
            if p["mediaSessionId"] as? Int == mediaSession { playerState = "PAUSED" }
        default:
            break
        }
    }

    /// Another sender's part: a status sent to every sender on the player.
    func broadcastMedia() { link.deliver(CastNS.media, transport, mediaStatus()) }
    func broadcastReceiver() { link.deliver(CastNS.receiver, "receiver-0", receiverStatus()) }
}

private final class FakeLink: CastLink, @unchecked Sendable {
    var onMessage: (@Sendable (CastProto.Message) -> Void)?
    var onEvent: (@Sendable (CastChannel.Event) -> Void)?
    var localIPv4: String? { "192.0.2.10" }
    let receiver: FakeReceiver
    var closed = false

    init(_ receiver: FakeReceiver) { self.receiver = receiver }

    func start() {
        let ready: () -> Void = { [self] in onEvent?(.ready) }
        if receiver.holdReady { receiver.heldReady = ready } else { DispatchQueue.main.async(execute: ready) }
    }

    func send(namespace: String, destination: String, source: String, payload: [String: Any]) {
        guard !closed else { return }
        DispatchQueue.main.async { [self] in receiver.receive(namespace, destination, payload, on: self) }
    }

    func close() { closed = true }

    /// A message from the receiver, through the real framing code.
    func deliver(_ ns: String, _ source: String, _ payload: [String: Any]) {
        guard !closed else { return }
        let text = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let msg = CastProto.decode(CastProto.encode(source: source, destination: "sender-0", namespace: ns, payload: text))!
        DispatchQueue.main.async { [self] in if !closed { onMessage?(msg) } }
    }

    /// The connection fails, as when Wi-Fi drops.
    func drop() {
        let event = onEvent
        closed = true
        DispatchQueue.main.async { event?(.failed("dropped by the test")) }
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: CastTarget against the pretend Chromecast

@MainActor private func castTargetTests() {
    let device = CastDeviceInfo(id: "fake-cast", name: "Test TV", model: "Chromecast",
                                endpoint: .hostPort(host: "192.0.2.10", port: 8009), capabilities: 5)
    let stoppedText = CastError.stoppedElsewhere("Test TV").localizedDescription

    func makeTarget(_ rx: FakeReceiver) -> (CastTarget, Box<[TargetStatus]>) {
        let t = CastTarget(device: device, link: rx.makeLink)
        let statuses = Box<[TargetStatus]>([])
        t.onStatus = { statuses.value.append($0) }
        return (t, statuses)
    }
    func request(hold: Double = 0, paused: Bool = false) -> LoadRequest {
        LoadRequest(url: URL(string: "http://192.0.2.1:8080/s/x/cast.m3u8")!, contentType: "application/x-mpegURL",
                    isHLS: true, title: "Film", startTime: 30, duration: 600, posterHoldSeconds: hold, startPaused: paused)
    }
    /// Starts `op` and lets the run loop turn until it has finished.
    func run<T>(_ seconds: Double = 10, _ op: @escaping @MainActor () async throws -> T) -> Result<T, Error>? {
        let result = Box<Result<T, Error>?>(nil)
        Task { @MainActor in
            do { result.value = .success(try await op()) } catch { result.value = .failure(error) }
        }
        spin(seconds) { result.value != nil }
        return result.value
    }
    func start(_ op: @escaping @MainActor () async throws -> Void) -> Box<Result<Void, Error>?> {
        let result = Box<Result<Void, Error>?>(nil)
        Task { @MainActor in
            do { result.value = .success(try await op()) } catch { result.value = .failure(error) }
        }
        return result
    }
    func isCancellation(_ r: Result<Void, Error>?) -> Bool {
        if case .failure(let e)? = r { return e is CancellationError }
        return false
    }

    // Connecting: two callers while "Connecting to X…" is up make one connection and one LAUNCH.
    do {
        let rx = FakeReceiver()
        rx.holdLaunch = true
        let (t, _) = makeTarget(rx)
        let a = start { _ = try await t.prepare() }
        let b = start { _ = try await t.prepare() }
        spin(3) { rx.heldLaunch != nil }
        spin(0.3)
        rx.heldLaunch?()
        spin(5) { a.value != nil && b.value != nil }
        let ok = (try? a.value?.get()) != nil && (try? b.value?.get()) != nil
        check(ok && rx.links.count == 1 && rx.sent("LAUNCH").count == 1,
              "Cast connects asked for twice at once share one connection (\(rx.links.count) connections, \(rx.sent("LAUNCH").count) LAUNCH)")
        _ = run { _ = try await t.prepare() }
        check(rx.links.count == 1 && rx.sent("GET_STATUS", ns: CastNS.receiver).count == 1,
              "Cast prepare when connected sends nothing new")
        t.disconnect()
    }

    // Volume: the TV's comes from RECEIVER_STATUS, with its mute; the stream's is ignored.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        spin(1.6)
        rx.volume = 0.25
        rx.muted = true
        rx.broadcastReceiver()
        spin(0.3)
        let volumes = statuses.value.filter { $0.volume != nil }
        let media = statuses.value.filter { $0.state == .playing }
        check(!media.isEmpty && media.allSatisfy { $0.volume == nil },
              "Cast media statuses carry no volume (the stream's 1.0 isn't the TV's): \(media.map(\.volume))")
        check(volumes.first?.volume == 0.3 && volumes.last?.volume == 0.25 && volumes.last?.muted == true && volumes.allSatisfy { $0.state == .idle },
              "Cast TV volume and mute come from RECEIVER_STATUS, as volume-only statuses (\(volumes.map(\.volume)))")
        t.setMuted(false)
        spin(0.3)
        let setMute = rx.sent("SET_VOLUME").last?["volume"] as? [String: Any]
        check(setMute?["muted"] as? Bool == false && setMute?["level"] == nil
              && statuses.value.filter { $0.volume != nil }.last?.muted == false,
              "Cast setMuted sends SET_VOLUME with the mute alone")
        t.disconnect()
    }

    // Another sender's video replaces ours: reported once, and Pause no longer reaches it.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        spin(1.3)
        check(statuses.value.contains { $0.state == .playing }, "Cast our own media session's statuses are reported")
        statuses.value = []
        rx.mediaSession = 9
        rx.playerState = "PLAYING"
        rx.broadcastMedia()
        spin(2.5)
        let errors = statuses.value.compactMap(\.error)
        check(errors == [stoppedText] && !statuses.value.contains { $0.state == .playing },
              "Cast another sender's media session is reported once as a takeover, never as ours (\(errors))")
        t.pause()
        spin(0.3)
        check(rx.sent("PAUSE").isEmpty, "Cast Pause after a takeover isn't sent to the other sender's video")
        t.disconnect()
    }

    // Stopped by voice or from another sender: IDLE with CANCELLED, reported once.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        spin(1.3)
        statuses.value = []
        rx.playerState = "IDLE"
        rx.idleReason = "CANCELLED"
        rx.broadcastMedia()
        spin(2.5)
        check(statuses.value.compactMap(\.error) == [stoppedText],
              "Cast playback stopped elsewhere (IDLE, CANCELLED) is reported once (\(statuses.value.compactMap(\.error)))")
        t.disconnect()
    }

    // Our own Stop: its CANCELLED is not reported as someone else's.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        spin(1.3)
        statuses.value = []
        t.stop()
        spin(0.3)
        rx.broadcastMedia()
        spin(1.5)
        check(rx.sent("STOP", ns: CastNS.media).count == 1 && statuses.value.allSatisfy { $0.error == nil },
              "Cast our own Stop is sent and its CANCELLED isn't reported")
        t.disconnect()
    }

    // The player closes (another app cast to the TV): one error, and later receiver statuses
    // say nothing about playing.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        spin(1.3)
        statuses.value = []
        rx.appRunning = false
        rx.mediaSession = 0
        rx.link.deliver(CastNS.connection, rx.transport, ["type": "CLOSE"])
        spin(0.3)
        rx.broadcastReceiver()
        rx.broadcastReceiver()
        spin(1.5)
        let errors = statuses.value.compactMap(\.error)
        check(errors == [stoppedText] && statuses.value.allSatisfy { $0.state == .idle },
              "Cast player closed elsewhere: one error, then volume-only statuses (\(statuses.value.map { "\($0.state)" }))")
        t.disconnect()
    }

    // Stop pressed while the TV is loading: the STOP it couldn't name a session for is sent once
    // the LOAD is answered, and no PLAY or polling follows.
    do {
        let rx = FakeReceiver()
        let (t, _) = makeTarget(rx)
        _ = run { _ = try await t.prepare() }
        rx.holdLoad = true
        let load = start { try await t.load(request(hold: 0.5)) }
        spin(3) { rx.heldLoad != nil }
        t.stop()
        rx.heldLoad?()
        spin(3) { load.value != nil }
        let stops = rx.sent("STOP", ns: CastNS.media)
        check(isCancellation(load.value) && stops.count == 1 && stops.first?["mediaSessionId"] as? Int == 1,
              "Cast Stop during LOAD: the answered session gets its STOP (\(stops))")
        let polls = rx.sent("GET_STATUS", ns: CastNS.media).count
        spin(1.5)
        check(rx.sent("PLAY").isEmpty && rx.sent("GET_STATUS", ns: CastNS.media).count == polls,
              "Cast Stop during LOAD: no PLAY after the poster hold, no polling")
        t.disconnect()
    }

    // A video loaded paused: autoplay off and no PLAY after the poster hold.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request(hold: 0.5, paused: true)) }
        spin(1.5)
        check(rx.sent("LOAD").first?["autoplay"] as? Bool == false && rx.sent("PLAY").isEmpty
              && statuses.value.last?.state == .paused,
              "Cast startPaused loads with autoplay off and stays paused")
        t.disconnect()
    }

    // A LOAD the player gives up on, having fetched nothing from this Mac, names the likely cause.
    do {
        let rx = FakeReceiver()
        rx.loadReply = "LOAD_FAILED"
        let (t, _) = makeTarget(rx)
        let r = run { try await t.load(request()) }
        var message = ""
        if case .failure(let e)? = r { message = e.localizedDescription }
        check(message == CastError.unreachable.localizedDescription,
              "Cast LOAD_FAILED with nothing fetched says the TV couldn't reach this Mac (\(message))")
        t.disconnect()
    }

    // Connection dropped, player still up: rejoined without LAUNCH, reported as reconnecting
    // then reconnected.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        statuses.value = []
        rx.link.drop()
        spin(5) { statuses.value.contains { $0.reconnected || $0.error != nil } }
        check(statuses.value.first?.reconnecting == true && statuses.value.contains { $0.reconnected }
              && rx.links.count == 2 && rx.sent("LAUNCH").count == 1,
              "Cast dropped connection rejoins the same player without LAUNCH (\(rx.links.count) connections, \(rx.sent("LAUNCH").count) LAUNCH)")
        t.disconnect()
    }

    // Connection dropped and the player gone meanwhile: an error, and nothing launched.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        statuses.value = []
        rx.link.drop()
        rx.appRunning = false
        spin(5) { statuses.value.contains { $0.reconnected || $0.error != nil } }
        check(statuses.value.contains { $0.error != nil } && !statuses.value.contains { $0.reconnected }
              && rx.sent("LAUNCH").count == 1,
              "Cast dropped connection with the player gone reports the loss and launches nothing")
        t.disconnect()
    }

    // Connection dropped and the player started afresh by another sender (a new session).
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        statuses.value = []
        rx.link.drop()
        rx.appSession = "session-2"
        spin(5) { statuses.value.contains { $0.reconnected || $0.error != nil } }
        check(statuses.value.contains { $0.error != nil } && !statuses.value.contains { $0.reconnected },
              "Cast dropped connection doesn't rejoin another sender's new player session")
        t.disconnect()
    }

    // Stop pressed while the connection was down reaches the TV once it is back.
    do {
        let rx = FakeReceiver()
        let (t, _) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        rx.link.drop()
        spin(0.2)
        t.stop()
        spin(5) { rx.links.count == 2 && !rx.sent("STOP", ns: CastNS.media).isEmpty }
        check(rx.sent("STOP", ns: CastNS.media).first?["mediaSessionId"] as? Int == 1,
              "Cast Stop while the connection was down is sent after rejoining")
        t.disconnect()
    }

    // Left while LAUNCH is on its way: the player it started is stopped, nothing more is said.
    do {
        let rx = FakeReceiver()
        rx.holdLaunch = true
        let (t, statuses) = makeTarget(rx)
        let prep = start { _ = try await t.prepare() }
        spin(3) { rx.heldLaunch != nil }
        t.disconnect()
        rx.heldLaunch?()
        spin(3) { prep.value != nil }
        spin(0.3)
        let stop = rx.sent("STOP", ns: CastNS.receiver)
        check(isCancellation(prep.value) && stop.first?["sessionId"] as? String == "session-1"
              && rx.link.closed && rx.sent("CONNECT").count == 1,
              "Cast left during LAUNCH stops the launched player and doesn't join it (\(stop))")
        check(statuses.value.allSatisfy { $0.error == nil && !$0.reconnected }, "Cast target left reports nothing more")
    }

    // Left while the connection is still opening: nothing is launched or stopped, and it closes.
    do {
        let rx = FakeReceiver()
        rx.holdReady = true
        let (t, _) = makeTarget(rx)
        let prep = start { _ = try await t.prepare() }
        spin(3) { rx.heldReady != nil }
        t.disconnect()
        rx.heldReady?()
        spin(3) { prep.value != nil }
        spin(0.3)
        check(isCancellation(prep.value) && rx.sent("LAUNCH").isEmpty && rx.sent("STOP").isEmpty && rx.link.closed,
              "Cast left while connecting launches nothing and closes")
    }

    // Left while the connection is down: one attempt rejoins the player to stop it.
    do {
        let rx = FakeReceiver()
        let (t, statuses) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        rx.link.drop()
        spin(0.2)
        t.disconnect()
        statuses.value = []
        spin(5) { !rx.sent("STOP", ns: CastNS.receiver).isEmpty }
        spin(0.3)
        check(rx.sent("STOP", ns: CastNS.receiver).first?["sessionId"] as? String == "session-1"
              && rx.links.count == 2 && rx.link.closed && rx.sent("LAUNCH").count == 1 && statuses.value.isEmpty,
              "Cast left while the connection was down still stops the player once it is reached")
    }

    // Disconnect when connected: STOP and CLOSE, as before.
    do {
        let rx = FakeReceiver()
        let (t, _) = makeTarget(rx)
        _ = run { try await t.load(request()) }
        t.disconnect()
        spin(0.3)
        check(rx.sent("STOP", ns: CastNS.receiver).count == 1 && rx.sent("CLOSE").count == 1 && rx.link.closed,
              "Cast disconnect stops the player and closes")
    }
}

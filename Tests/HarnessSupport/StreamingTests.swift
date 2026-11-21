import Foundation

// Harness checks for streaming: segment grids, ffmpeg arguments, sessions, the HTTP server, probing.
// Uses check(_:_:), spin, await_ and fetch from Helpers.swift, and the global mediaDir (the
// test media folder, from the command line) that harness.swift defines.
func streamingTests() {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("driftcast-streaming-tests", isDirectory: true)
    try? fm.removeItem(at: work)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    let ffmpeg = FFmpeg.ffmpeg!
    let settings = EncoderSettings(hardware: true, videoBitrateMbps: 8, maxResolution: 2160, forceTranscode: false,
                                   castHEVC: .auto, castAudio: .aac, castPassthrough: false, appleSurround: .eac3)
    var forced = settings; forced.forceTranscode = true
    var software = forced; software.hardware = false

    @discardableResult
    func tool(_ exe: URL, _ args: [String]) -> String {
        let p = Process(); p.executableURL = exe; p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    func make(_ name: String, _ args: [String]) -> URL {
        let url = work.appendingPathComponent(name)
        tool(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + args + [url.path])
        return url
    }
    func probe(_ url: URL) -> MediaInfo { try! await_ { try await MediaProbe.shared.probe(url) }.get() }
    func keyGrid(_ url: URL, _ info: MediaInfo) -> SegmentGrid {
        let keys = try! await_ { try await KeyframeIndex.shared.keyframes(for: url, streamIndex: info.video!.index) }.get()
        return .keyframes(keys.map { $0 - info.startTime }, duration: info.duration)
    }
    func running(_ pattern: String) -> String {
        tool(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", pattern]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Where the picture of a served (rebased) segment starts on the stream's timeline.
    func videoStart(_ segment: Data, _ initData: Data) -> Double? {
        guard let video = MP4Boxes.tracks(inInit: initData).first(where: \.isVideo) else { return nil }
        let d = [UInt8](segment)
        func u32(_ o: Int) -> UInt64 { o + 4 <= d.count ? d[o..<o + 4].reduce(0) { $0 << 8 | UInt64($1) } : 0 }
        func each(_ start: Int, _ end: Int, _ visit: (String, Int, Int) -> Void) {
            var o = start
            while o + 8 <= end {
                let size = Int(u32(o))
                guard size >= 8, o + size <= end else { return }
                visit(String(decoding: d[o + 4..<o + 8], as: UTF8.self), o + 8, o + size)
                o += size
            }
        }
        var found: Double?
        each(0, d.count) { type, s, e in
            guard type == "moof" else { return }
            each(s, e) { type, s, e in
                guard type == "traf" else { return }
                var track: UInt64 = 0
                each(s, e) { type, s, _ in
                    if type == "tfhd" { track = u32(s + 4) }
                    if type == "tfdt", track == UInt64(video.id), found == nil {
                        let time = d[s] == 1 ? u32(s + 4) << 32 | u32(s + 8) : u32(s + 4)
                        found = Double(time) / Double(video.timescale) + video.presentationOffset
                    }
                }
            }
        }
        return found
    }

    // MARK: Segment grids

    let unknown = SegmentGrid.keyframes([0, 2, 4], duration: 0)
    check(unknown.count >= 1 && unknown.start(of: unknown.index(at: 10)) >= 0, "a keyframe grid of unknown length is never empty (\(unknown.starts))")
    let none = SegmentGrid.keyframes([], duration: 0)
    check(none.count == 1 && none.start(of: none.index(at: 0)) == 0, "no keyframes and no length still give one segment (\(none.starts))")
    let late = SegmentGrid.keyframes([0.8, 2.8, 4.8], duration: 10)
    check(late.starts == [0, 2.8, 4.8], "a film whose first keyframe comes late starts its first segment at 0, not with a segment no file holds (\(late.starts))")

    // A recording that starts part-way through a group of pictures: the first keyframe is 0.8 s in.
    let gop2 = make("gop2.mkv", ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                                 "-t", "30", "-c:v", "libx264", "-preset", "ultrafast", "-g", "50", "-keyint_min", "50", "-sc_threshold", "0", "-bf", "0",
                                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"])
    let midGOP = make("midgop.mkv", ["-i", gop2.path, "-ss", "1.2", "-c", "copy", "-copyinkf"])
    let midInfo = probe(midGOP)
    let midGrid = keyGrid(midGOP, midInfo)
    let midPlan = StreamPlanner.plan(info: midInfo, file: midGOP, profile: .apple(), settings: settings, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    let midSession = StreamSession(plan: midPlan, source: midGOP, duration: midInfo.duration, grid: midGrid, cues: nil)
    let midStarted = Date()
    let midStart = await_ { try await midSession.start(at: 0) }
    let midSecond = try? await_({ try await midSession.segment(1) }).get()
    let midAt = midSecond.flatMap { s in midSession.initSegment().flatMap { videoStart(s, $0) } }
    check((try? midStart.get()) != nil && Date().timeIntervalSince(midStarted) < 20 && midAt.map { abs($0 - midGrid.start(of: 1)) < 0.1 } == true,
          "a file that starts mid-GOP plays from the start, segment 1 at its place (\(midAt.map { String(format: "%.2f", $0) } ?? "nil") for \(midGrid.starts.prefix(3))) \((try? midStart.get()) == nil ? "\(midStart)" : "")")
    midSession.stop()

    // Audio delayed by 0.6 s, both streams copied, one-second groups of pictures.
    let gop1 = make("gop1.mkv", ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                                 "-t", "20", "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0",
                                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"])
    let gopInfo = probe(gop1)
    let gopGrid = keyGrid(gop1, gopInfo)
    let delayed = StreamPlanner.plan(info: gopInfo, file: gop1, profile: .apple(), settings: settings, audioIndex: nil, subtitle: nil,
                                     options: PlaybackOptions(avSyncOffset: 0.6))
    check(delayed.isCopyingVideo && delayed.isRemuxOnly && delayed.mode == .hls, "audio delay test: video and audio are copied")
    for at in [0.0, 5.0] {
        let session = StreamSession(plan: delayed, source: gop1, duration: gopInfo.duration, grid: gopGrid, cues: nil)
        let started = Date()
        let result = await_ { try await session.start(at: at) }
        let wanted = gopGrid.index(at: at)
        let later = try? await_({ try await session.segment(wanted + 2) }).get()
        let laterAt = later.flatMap { s in session.initSegment().flatMap { videoStart(s, $0) } }
        check((try? result.get()) != nil && Date().timeIntervalSince(started) < 20
              && abs((session.producedRange?.lowerBound ?? -1) - gopGrid.start(of: wanted)) < 0.1
              && laterAt.map { abs($0 - gopGrid.start(of: wanted + 2)) < 0.1 } == true,
              "with the audio 0.6 s late, a start at \(at) s lands on its segment (\(session.producedRange.map { "\($0)" } ?? "nil"), segment \(wanted + 2) at \(laterAt.map { String(format: "%.2f", $0) } ?? "nil")) \((try? result.get()) == nil ? "\(result)" : "")")
        session.stop()
    }

    // MARK: HTTP

    // A segment that can't be made: the converter has no file to read.
    let mp4 = mediaDir.appendingPathComponent("simple.mp4")
    let mp4Info = probe(mp4)
    var brokenPlan = StreamPlanner.plan(info: mp4Info, file: mp4, profile: .apple(), settings: settings, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    brokenPlan.mode = .hls
    let missing = work.appendingPathComponent("driftcast-missing-\(UUID().uuidString.prefix(8)).mp4")
    let broken = StreamSession(plan: brokenPlan, source: missing, duration: 30, grid: .fixed(duration: 30), cues: nil)
    MediaServer.shared.register(broken)
    let segURL = try! await_ { await MediaServer.shared.url(path: "/s/\(broken.id)/seg00000.m4s", host: "127.0.0.1") }.get()
    let (rangedStatus, rangedBody, _) = fetch(segURL, range: "bytes=0-")
    check(rangedStatus == 503 && String(decoding: rangedBody, as: UTF8.self).contains("converter"),
          "a failed segment asked for with a byte range is still a 503 with its message (\(rangedStatus))")
    let (farStatus, _, _) = fetch(segURL.deletingLastPathComponent().appendingPathComponent("seg00001.m4s"), range: "bytes=100000-")
    check(farStatus == 503, "and a range past the end of the message doesn't turn it into a 416 (\(farStatus))")
    let (notFound, _, _) = fetch(segURL.deletingLastPathComponent().appendingPathComponent("nothing.bin"), range: "bytes=0-3")
    check(notFound == 404, "a missing file asked for with a range is a 404 (\(notFound))")
    ErrorLog.flush()
    let logged = ((try? String(contentsOf: ErrorLog.url, encoding: .utf8)) ?? "").split(separator: "\n")
        .filter { $0.contains("Converter") && $0.contains(missing.lastPathComponent) }.count
    check(logged == 1, "a conversion that fails while a device plays is written to the error log, once per stream (\(logged))")
    MediaServer.shared.unregister(broken)
    broken.stop()

    // MARK: ffmpeg jobs

    // A job being stopped can't be frozen again by the pacing loop.
    let marker = "dc-race-\(UUID().uuidString.prefix(8))"
    let raceJob = TranscodeJob(number: 0, startSegment: 0, arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-re", "-f", "lavfi",
                                                                       "-i", "testsrc2=size=64x64:rate=10", "-metadata", "title=\(marker)", "-f", "null", "-"],
                               directory: work)
    try? raceJob.start()
    spin(0.3)
    raceJob.setPaused(true)
    raceJob.stop()
    raceJob.setPaused(true)
    spin(3) { !raceJob.isRunning }
    check(!raceJob.isRunning && !raceJob.isPaused, "a job told to stop exits even if it is asked to freeze as it goes")
    tool(URL(fileURLWithPath: "/usr/bin/pkill"), ["-9", "-f", marker])

    // A conversion of the long file, paced a few minutes ahead of what is asked for.
    let long = mediaDir.appendingPathComponent("long.mkv")
    let longInfo = probe(long)
    let longGrid = SegmentGrid.fixed(duration: longInfo.duration)
    let longPlan = StreamPlanner.plan(info: longInfo, file: long, profile: .apple(), settings: forced, audioIndex: nil, subtitle: nil, options: PlaybackOptions())

    // A session that has been stopped starts no more ffmpeg.
    let afterStop = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    check((try? await_ { try await afterStop.start(at: 0) }.get()) != nil, "conversion of the long file started")
    afterStop.stop()
    let lateRequest = Task { try await afterStop.segment(200) }
    spin(0.5)
    let leftover = running("\(afterStop.id)/j1-")   // j0 is the one stopped
    let lateResult = await_ { try await lateRequest.value }
    check(leftover.isEmpty && (try? lateResult.get()) == nil, "a request arriving after the stream has stopped starts no converter and fails at once (\(leftover))")

    // Jobs pushed out by a far seek take their files with them.
    let seeking = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    let seekDir = StreamSession.temporaryRoot.appendingPathComponent(seeking.id, isDirectory: true)
    func files(_ prefix: String) -> Int { ((try? fm.contentsOfDirectory(atPath: seekDir.path)) ?? []).filter { $0.hasPrefix(prefix) }.count }
    check((try? await_ { try await seeking.start(at: 0) }.get()) != nil, "conversion of the long file started (\(longGrid.count) segments)")
    spin(1)
    let firstJobFiles = files("j0-")
    let far1 = await_ { try await seeking.segment(longGrid.count / 3) }
    let far2 = await_ { try await seeking.segment(longGrid.count * 2 / 3) }
    spin(12) { files("j0-") == 0 }
    check((try? far1.get()) != nil && (try? far2.get()) != nil && firstJobFiles > 3 && files("j0-") == 0,
          "after two far seeks the first job's \(firstJobFiles) files are deleted (\(files("j0-")) left)")
    seeking.stop()

    // Quitting stops every stream, the ones still starting included.
    let starting = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    let kept = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    MediaServer.shared.register(starting)
    MediaServer.shared.register(kept)
    _ = await_ { try await starting.start(at: 0) }
    _ = await_ { try await kept.start(at: 0) }
    MediaServer.shared.stopAll(except: kept)
    spin(1.5)
    let keptURL = try! await_ { await MediaServer.shared.url(path: kept.streamPath, host: "127.0.0.1") }.get()
    let (keptStatus, _, _) = fetch(keptURL)
    check(running("\(starting.id)/j").isEmpty && keptStatus == 200 && !running("\(kept.id)/j").isEmpty,
          "stopping every stream but one ends the others' ffmpeg and leaves that one playing")
    MediaServer.shared.unregister(kept)
    kept.stop()

    // The card sits where a part-way start began; seeking before it needs a new stream.
    let carded = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    carded.intro = StreamSession.Intro(card: Data(), size: CGSize(width: 640, height: 360), atSegment: 100, hardware: true, format: TitleCard.Format())
    let atStart = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    atStart.intro = StreamSession.Intro(card: Data(), size: CGSize(width: 640, height: 360), atSegment: 0, hardware: true, format: TitleCard.Format())
    check(carded.cardFileTime == longGrid.start(of: 100) && atStart.cardFileTime == nil,
          "where the card sits is known when it is part-way in (\(carded.cardFileTime.map { "\($0)" } ?? "nil")), and nil at the start")

    // ffmpeg and ffprobe runs end when they are no longer wanted.
    let sleep = URL(fileURLWithPath: "/bin/sleep")
    let early = Task { () -> Result<Data, Error> in
        withUnsafeCurrentTask { $0?.cancel() }
        do { return .success(try await FFmpeg.run(sleep, ["7.31"])) } catch { return .failure(error) }
    }
    let earlyResult = try? await_ { await early.value }.get()
    var earlyCanceled = false
    if case .failure(let e)? = earlyResult { earlyCanceled = e is CancellationError }
    check(earlyCanceled && running("sleep 7.31").isEmpty, "a run canceled before it starts never starts")
    let midway = Task { try await FFmpeg.run(sleep, ["7.32"]) }
    spin(0.5)
    midway.cancel()
    let started = Date()
    let midResult = await_ { try await midway.value }
    var midCanceled = false
    if case .failure(let e) = midResult { midCanceled = e is CancellationError }
    check(midCanceled && Date().timeIntervalSince(started) < 2 && running("sleep 7.32").isEmpty, "a run canceled part-way ends its process (\(midResult))")
    let timed = Date()
    let slow = await_ { try await FFmpeg.run(sleep, ["7.33"], timeout: 0.5) }
    var timedOut = false
    if case .failure(let e) = slow { timedOut = e is FFmpeg.TimedOut }
    spin(0.5)
    check(timedOut && Date().timeIntervalSince(timed) < 3 && running("sleep 7.33").isEmpty, "a run past its time limit is ended (\(slow))")

    // MARK: Probing

    // A file replaced under the same name is probed again.
    let replaced = work.appendingPathComponent("replaced.mkv")
    try! Data(contentsOf: mp4).write(to: replaced)
    let before = probe(replaced)
    try! Data(contentsOf: mediaDir.appendingPathComponent("sdr444.mkv")).write(to: replaced)
    let after = probe(replaced)
    check(abs(before.duration - 30) < 0.5 && abs(after.duration - 12) < 0.5, "a file replaced under the same name is probed again (\(before.duration) then \(after.duration))")

    func video(_ w: Int, _ h: Int, fps: Double = 24, codec: String = "h264", level: Int = 40) -> MediaInfo.Video {
        MediaInfo.Video(index: 0, codec: codec, codecTag: codec == "hevc" ? "hvc1" : "avc1", profile: nil, level: level, pixFmt: "yuv420p",
                        width: w, height: h, fps: fps, colorTransfer: nil, isDolbyVision: false)
    }
    check(video(1080, 1920).resolutionName == "1080p" && video(720, 1280).resolutionName == "720p" && video(360, 640).resolutionName == "360p"
          && video(1920, 1080).resolutionName == "1080p" && video(3840, 1600).resolutionName == "4K",
          "portrait video is named by its short side: \(video(1080, 1920).resolutionName), \(video(720, 1280).resolutionName), \(video(360, 640).resolutionName)")

    // MARK: Picture size and frame rate

    func info(_ v: MediaInfo.Video) -> MediaInfo { MediaInfo(duration: 60, formatName: "matroska", bitRate: nil, video: v, audio: [], subtitles: []) }
    let classic = DeviceProfile.chromecast(model: "Chromecast", settings: settings)
    let scope = StreamPlanner.plan(info: info(video(3840, 1600)), file: mp4, profile: classic, settings: settings, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    let scopeArgs = scope.ffmpegArguments(input: mp4, startTime: 0, limitSeconds: nil, outputDirectory: work, filePrefix: "x")
    let scopeSession = StreamSession(plan: scope, source: mp4, duration: 60, grid: .fixed(duration: 60), cues: nil)
    check(scope.outputVideoSize == CGSize(width: 1920, height: 800) && scopeArgs.joined(separator: " ").contains("scale_vt=w=1920:h=800")
          && scopeSession.castPlaylist()?.contains("RESOLUTION=1920x800") == true,
          "a 3840x1600 film for a 1080p Chromecast fits 1920 wide: \(scope.outputVideoSize.map { "\($0)" } ?? "nil")")
    let scopeCPU = scope.ffmpegArguments(input: mp4, startTime: 0, limitSeconds: nil, outputDirectory: work, filePrefix: "x", route: .software)
    check(scopeCPU.joined(separator: " ").contains("min(800,ih)"), "the software scaler is given the same height")
    let ultrawide = StreamPlanner.plan(info: info(video(2560, 1080, codec: "hevc", level: 120)), file: mp4,
                                       profile: .chromecast(model: "Chromecast HD", settings: settings), settings: settings,
                                       audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    check(ultrawide.isTranscodingVideo && ultrawide.outputVideoSize.map { $0.width <= 1920 && Int($0.width) % 2 == 0 && Int($0.height) % 2 == 0 } == true,
          "2560x1080 is converted for a 1080p device, to an even size that fits: \(ultrawide.outputVideoSize.map { "\($0)" } ?? "nil")")
    let dci = StreamPlanner.plan(info: info(video(4096, 2160, codec: "hevc", level: 153)), file: mp4, profile: .apple(), settings: settings,
                                 audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    check(dci.isCopyingVideo, "cinema 4K (4096 wide) is still sent untouched to a 4K device")
    let odd = StreamPlanner.plan(info: info(video(1279, 719)), file: mp4, profile: .apple(), settings: forced, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    check(odd.outputVideoSize.map { Int($0.width) % 2 == 0 && Int($0.height) % 2 == 0 } == true, "an odd-sized picture is converted to an even size: \(odd.outputVideoSize.map { "\($0)" } ?? "nil")")

    let fast = StreamPlanner.plan(info: info(video(1280, 720, fps: 119.88)), file: mp4, profile: .chromecast(model: "Chromecast Ultra", settings: settings),
                                  settings: forced, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    let fastPlaylist = StreamSession(plan: fast, source: mp4, duration: 60, grid: .fixed(duration: 60), cues: nil).castPlaylist() ?? ""
    check(fast.ffmpegArguments(input: mp4, startTime: 0, limitSeconds: nil, outputDirectory: work, filePrefix: "x").contains("-fpsmax")
          && fastPlaylist.contains("FRAME-RATE=60.000"), "a 120 fps clip converted to 60 fps says 60 in the Cast playlist")

    // MARK: The container, by one name

    do {
        func c(_ format: String, _ file: String) -> String { MediaInfo.containerName(formatName: format, file: URL(fileURLWithPath: "/tmp/\(file)")) }
        let family = "mov,mp4,m4a,3gp,3g2,mj2"
        check(c(family, "a.mp4") == "MP4" && c(family, "a.mov") == "QuickTime (MOV)" && c(family, "a.m4v") == "MP4 (M4V)",
              "one reader's list is named by the file: \(c(family, "a.mp4")), \(c(family, "a.mov")), \(c(family, "a.m4v"))")
        check(c("matroska,webm", "a.mkv") == "Matroska (MKV)" && c("matroska,webm", "a.webm") == "WebM", "Matroska and WebM told apart")
        check(c("matroska,webm", "a.mp4") == "Matroska (MKV)", "a file whose extension lies is named by what is in it: \(c("matroska,webm", "a.mp4"))")
        check(c("mpegts", "a.m2ts") == "Blu-ray (M2TS)" && c("avi", "a.avi") == "AVI" && c("flac", "a.flac") == "FLAC",
              "single readers: \(c("mpegts", "a.m2ts")), \(c("avi", "a.avi")), \(c("flac", "a.flac"))")
        check(!c(family, "a.mp4").contains(","), "never a list")
    }

    // MARK: The casting picture's details

    do {
        func audio(_ codec: String, _ channels: Int) -> MediaInfo.Audio {
            MediaInfo.Audio(index: 1, codec: codec, profile: nil, channels: channels, language: "eng", title: nil, isDefault: true)
        }
        func details(_ v: MediaInfo.Video?, _ a: MediaInfo.Audio?, on profile: DeviceProfile, file: String = "film.mp4",
                     subtitle: SubtitleChoice? = nil, text: Bool = false, with s: EncoderSettings? = nil) -> CastingDetails? {
            let info = MediaInfo(duration: 60, formatName: "mov", bitRate: nil, video: v, audio: a.map { [$0] } ?? [], subtitles: [])
            return CastingDetails(plan: StreamPlanner.plan(info: info, file: URL(fileURLWithPath: "/tmp/\(file)"), profile: profile, settings: s ?? settings,
                                                           audioIndex: nil, subtitle: subtitle, subtitleIsText: text, options: PlaybackOptions()))
        }
        check(CastingDetails(plan: nil) == nil, "casting details: nothing to say before the video is planned")
        let asIs = details(video(1920, 1080), audio("aac", 2), on: classic)
        check(asIs?.file == "1080p · H.264 · AAC Stereo" && asIs?.doing == "Playing as is",
              "casting details: a file the TV plays itself (\(asIs?.file ?? "nil") / \(asIs?.doing ?? "nil"))")
        let repack = details(video(1920, 1080), audio("aac", 2), on: classic, file: "film.mkv")
        check(repack?.doing == "Repackaged, no quality loss", "casting details: an MKV the TV can't open is repackaged (\(repack?.doing ?? "nil"))")
        var hdr = video(3840, 2160, codec: "hevc", level: 153)
        hdr.pixFmt = "yuv420p10le"; hdr.colorTransfer = "smpte2084"
        let converted = details(hdr, audio("eac3", 6), on: classic, file: "film.mkv")
        check(converted?.file == "4K HDR10 · HEVC · Dolby Digital+ 5.1" && converted?.doing.hasPrefix("Converting to 1080p H.264") == true,
              "casting details: 4K HDR on a 1080p Chromecast is converted (\(converted?.file ?? "nil") / \(converted?.doing ?? "nil"))")
        let wide = details(video(3840, 1600), audio("aac", 2), on: classic, file: "film.mkv")
        check(wide?.doing == "Converting to 1080p H.264", "casting details: a wide film converted to 1920x800 is called 1080p, not 800p (\(wide?.doing ?? "nil"))")
        let sound = details(video(1920, 1080), audio("dts", 6), on: classic, file: "film.mkv")
        check(sound?.file == "1080p · H.264 · DTS 5.1" && sound?.doing.hasPrefix("Picture as is, sound converted to ") == true,
              "casting details: only the sound is converted (\(sound?.doing ?? "nil"))")
        let song = details(nil, audio("flac", 2), on: classic, file: "song.flac")
        check(song?.file == "FLAC Stereo" && song?.doing.isEmpty == false, "casting details: a sound file names its sound alone (\(song?.file ?? "nil") / \(song?.doing ?? "nil"))")
        let srt = MediaInfo.Subtitle(index: 2, codec: "subrip", language: "eng", title: nil, isDefault: false, isForced: false)
        let subbed = details(video(1920, 1080), audio("aac", 2), on: classic, file: "film.mkv", subtitle: .embedded(srt))
        check(subbed?.doing == "Repackaged, no quality loss · English subtitles", "casting details: the subtitle that is on is named (\(subbed?.doing ?? "nil"))")
        let unnamed = MediaInfo.Subtitle(index: 2, codec: "subrip", language: nil, title: nil, isDefault: false, isForced: false)
        let anon = details(video(1920, 1080), audio("aac", 2), on: classic, file: "film.mkv", subtitle: .embedded(unnamed))
        check(anon?.doing.hasSuffix(" · Subtitles on") == true, "casting details: a subtitle of unknown language is just on (\(anon?.doing ?? "nil"))")
        let pgs = MediaInfo.Subtitle(index: 2, codec: "hdmv_pgs_subtitle", language: "fre", title: nil, isDefault: false, isForced: false)
        let drawn = details(video(1920, 1080), audio("aac", 2), on: classic, file: "film.mkv", subtitle: .embedded(pgs))
        check(drawn?.doing == "Converting to 1080p H.264 · French subtitles", "casting details: a picture subtitle drawn in means converting (\(drawn?.doing ?? "nil"))")
    }

    // MARK: Burned-in picture subtitles

    // Four copies of test.sup one after another (the copies count from 0): a cue on screen from 60 to 63 s.
    let sup = mediaDir.appendingPathComponent("test.sup")
    let list = work.appendingPathComponent("sup-list.txt")
    try! ("ffconcat version 1.0\n" + String(repeating: "file '\(sup.path)'\nduration 20\n", count: 4)).write(to: list, atomically: true, encoding: .utf8)
    let longSup = make("long.sup", ["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c:s", "copy", "-f", "sup"])
    let gray = make("gray.mp4", ["-f", "lavfi", "-i", "color=c=gray:size=1280x720:rate=4", "-t", "80", "-c:v", "libx264", "-preset", "ultrafast",
                                 "-g", "8", "-pix_fmt", "yuv420p"])
    let grayInfo = probe(gray)
    /// Frame checksums of what the planner's own inputs and filters make, from `start`.
    func frames(_ plan: StreamPlan, _ input: URL, at start: Double, count: Int) -> [String] {
        let args = plan.ffmpegArguments(input: input, startTime: start, limitSeconds: nil, outputDirectory: work, filePrefix: "f", route: .software)
        guard let graph = args.firstIndex(of: "-filter_complex") else { return [] }
        let out = work.appendingPathComponent("frames.md5")
        tool(ffmpeg, Array(args[..<graph]) + ["-filter_complex", args[graph + 1], "-map", "[vout]", "-frames:v", "\(count)", "-f", "framemd5", out.path])
        return ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }.map { String($0.split(separator: ",").last ?? "") }
    }
    let plain = StreamPlanner.plan(info: grayInfo, file: gray, profile: .apple(), settings: software, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    let burned = StreamPlanner.plan(info: grayInfo, file: gray, profile: .apple(), settings: software, audioIndex: nil, subtitle: .external(longSup), options: PlaybackOptions())
    let burnArgs = burned.ffmpegArguments(input: gray, startTime: 62, limitSeconds: nil, outputDirectory: work, filePrefix: "f")
    let supAt = burnArgs.firstIndex(of: longSup.path) ?? 0
    check(burnArgs[..<supAt].suffix(6) == ["-seek_timestamp", "1", "-noaccurate_seek", "-ss", "32.0000", "-i"],
          "the subtitle file is read from a little before the start, by its own clock: \(burnArgs[..<supAt].suffix(6))")
    let withSubs = frames(burned, gray, at: 62, count: 4), without = frames(plain, gray, at: 62, count: 4)
    check(withSubs.count == 4 && without.count == 4 && zip(withSubs, without).allSatisfy { $0 != $1 },
          "a subtitle already on screen where a stream starts is drawn in (\(zip(withSubs, without).filter { $0 != $1 }.count) of \(withSubs.count) frames)")
    // An embedded PGS track still goes through the canvas scaler; the line on screen at a
    // part-way start (5 to 8 s here) is drawn from the second frame on.
    let pgs = mediaDir.appendingPathComponent("pgs.mkv")
    let pgsInfo = probe(pgs)
    if let track = pgsInfo.subtitles.first(where: \.isPicture) {
        let pgsPlain = StreamPlanner.plan(info: pgsInfo, file: pgs, profile: .apple(), settings: software, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
        let pgsBurned = StreamPlanner.plan(info: pgsInfo, file: pgs, profile: .apple(), settings: software, audioIndex: nil, subtitle: .embedded(track), options: PlaybackOptions())
        let drawn = frames(pgsBurned, pgs, at: 6, count: 6).dropFirst(), undrawn = frames(pgsPlain, pgs, at: 6, count: 6).dropFirst()
        check(drawn.count == 5 && undrawn.count == 5 && zip(drawn, undrawn).allSatisfy { $0 != $1 },
              "an embedded picture subtitle is drawn in at a part-way start (\(zip(drawn, undrawn).filter { $0 != $1 }.count) of \(drawn.count) frames)")
    } else { check(false, "pgs.mkv has a picture subtitle track") }
    // A 1280x720 subtitle picture over a 640x360 film is fitted to it, not cut off.
    let small = make("small.mp4", ["-f", "lavfi", "-i", "color=c=gray:size=640x360:rate=4", "-t", "10", "-c:v", "libx264", "-preset", "ultrafast",
                                   "-g", "8", "-pix_fmt", "yuv420p"])
    let smallInfo = probe(small)
    let smallPlain = StreamPlanner.plan(info: smallInfo, file: small, profile: .apple(), settings: software, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
    let smallBurned = StreamPlanner.plan(info: smallInfo, file: small, profile: .apple(), settings: software, audioIndex: nil, subtitle: .external(sup), options: PlaybackOptions())
    let fitted = frames(smallBurned, small, at: 1.5, count: 4), bare = frames(smallPlain, small, at: 1.5, count: 4)
    check(fitted.count == 4 && bare.count == 4 && zip(fitted, bare).allSatisfy { $0 != $1 },
          "a subtitle picture larger than the film is scaled onto it (\(zip(fitted, bare).filter { $0 != $1 }.count) of \(fitted.count) frames show it)")

    try? fm.removeItem(at: work)
}

import CryptoKit
import Foundation

/// The vendored macSubtitleOCR sources print diagnostics to this stream.
nonisolated(unsafe) var stderr = FileHandleOutputStream(.standardError)

/// Turns PGS and VobSub picture subtitles into text with the Vision framework, using the
/// parsers and recognizer from macSubtitleOCR (MIT, see OCR/LICENSE-macSubtitleOCR.txt).
///
/// Results are cached as SRT files keyed by the media file and track, so a film is read once.
actor PictureSubtitleOCR {
    static let shared = PictureSubtitleOCR()

    /// A reading under way, shared by everyone waiting for the same track of the same file.
    private struct Reading {
        let id: UUID
        let task: Task<[SubtitleCue], Error>
        let progress: ProgressFanOut
        var waiters: Set<UUID> = []
    }

    /// Readings under way, by cache file. Keyed by the track alone ("embedded-3"), the same in every
    /// episode, a second video started while the first was still being read was handed the first
    /// one's subtitles.
    private var inFlight: [String: Reading] = [:]
    /// Readings that failed in this run, by cache file, so a track that can't be read isn't walked
    /// again in full on every start. A changed file has a new cache file and is tried again.
    private var failed: [String: Error] = [:]

    enum Failure: LocalizedError {
        case unsupported
        case trackNotFound
        case nothingRecognized

        var errorDescription: String? {
            switch self {
            case .unsupported: return "These subtitles can't be converted to text."
            case .trackNotFound: return "The subtitle track couldn't be read from the file."
            case .nothingRecognized: return "No text was recognized in the subtitles."
            }
        }
    }

    /// PGS and VobSub inside MKV, or as .sup / .idx files. Other containers keep burning in.
    nonisolated static func supports(_ choice: SubtitleChoice, media: URL) -> Bool {
        switch choice {
        case .embedded(let s):
            guard ["mkv", "mks", "mk3d"].contains(media.pathExtension.lowercased()) else { return false }
            return s.codec == "hdmv_pgs_subtitle" || s.codec == "dvd_subtitle"
        case .external(let url):
            return ["sup", "idx", "sub"].contains(url.pathExtension.lowercased())
        }
    }

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/OCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(for choice: SubtitleChoice, media: URL) -> URL {
        let source: URL
        if case .external(let u) = choice { source = u } else { source = media }
        // From the file system each time: a URL keeps resource values it has read, so a file replaced
        // while the app runs could keep its old date and with it the old reading.
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(mtime)|\(choice.id)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(String(digest.prefix(32)) + ".srt")
    }

    /// Whether this picture subtitle of this video has been read and its text kept, so there is a
    /// reading to forget.
    nonisolated static func hasReading(of choice: SubtitleChoice, media: URL) -> Bool {
        supports(choice, media: media) && FileManager.default.fileExists(atPath: cacheFile(for: choice, media: media).path)
    }

    /// Forgets what was read from one picture subtitle of one video, so the next play reads it again:
    /// the kept text, a failure remembered from this run, and a reading still under way (which ends
    /// with `CancellationError` for whoever waits on it). For a reading that came out wrong, such as
    /// the wrong language, or the wrong track before the track order was fixed.
    func forgetReading(of choice: SubtitleChoice, media: URL) {
        let file = Self.cacheFile(for: choice, media: media)
        try? FileManager.default.removeItem(at: file)
        failed[file.path] = nil
        if let reading = inFlight.removeValue(forKey: file.path) {
            reading.task.cancel()
        }
    }

    /// Cues for the subtitle, running OCR if there is no cached result yet.
    ///
    /// `progress` hears how many pictures have been read out of how many, on whatever thread the work
    /// is on. Canceling the calling task stops the reading once nobody else is waiting for it, and
    /// throws `CancellationError`.
    func cues(for choice: SubtitleChoice, media: URL, info: MediaInfo, preferredLanguage: String,
              progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> [SubtitleCue] {
        guard Self.supports(choice, media: media) else { throw Failure.unsupported }
        let file = Self.cacheFile(for: choice, media: media)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let cues = WebVTT.parse(text)
            if !cues.isEmpty { return cues }
        }
        let key = file.path
        if let error = failed[key] { throw error }

        if inFlight[key] == nil {
            let id = UUID()
            let fanOut = ProgressFanOut()
            let task = Task<[SubtitleCue], Error> {
                // Once it ends, its result is on disk or in `failed`, so it is no longer joined.
                defer { if self.inFlight[key]?.id == id { self.inFlight[key] = nil } }
                do {
                    let srt = try await Self.recognize(choice, media: media, info: info,
                                                       preferredLanguage: preferredLanguage,
                                                       progress: { done, total in fanOut.send(done, total) })
                    try srt.write(to: file, atomically: true, encoding: .utf8)
                    let cues = WebVTT.parse(srt)
                    guard !cues.isEmpty else { throw Failure.nothingRecognized }
                    return cues
                } catch {
                    if !(error is CancellationError) {
                        self.failed[key] = error
                    }
                    throw error
                }
            }
            inFlight[key] = Reading(id: id, task: task, progress: fanOut)
        }
        let waiter = UUID()
        inFlight[key]!.waiters.insert(waiter)
        let task = inFlight[key]!.task
        let readingID = inFlight[key]!.id
        if let progress { inFlight[key]!.progress.add(waiter, progress) }
        defer { leave(key, reading: readingID, waiter: waiter) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(key, reading: readingID, waiter: waiter) }
        }
    }

    /// One waiter is done with a reading. When nobody is left waiting for one still running, it is
    /// stopped, after a moment's grace: changing the audio track or the subtitle size reloads the same
    /// video, which asks for the same reading again at once, and should find it still going.
    private func leave(_ key: String, reading id: UUID, waiter: UUID) {
        guard var reading = inFlight[key], reading.id == id else { return }
        reading.waiters.remove(waiter)
        reading.progress.remove(waiter)
        inFlight[key] = reading
        guard reading.waiters.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.stopIfUnwanted(key, reading: id)
        }
    }

    private func stopIfUnwanted(_ key: String, reading id: UUID) {
        guard let reading = inFlight[key], reading.id == id, reading.waiters.isEmpty else { return }
        reading.task.cancel()
        // Whoever asks next starts a reading of their own rather than joining one being stopped.
        inFlight[key] = nil
    }

    private static func recognize(_ choice: SubtitleChoice, media: URL, info: MediaInfo, preferredLanguage: String,
                                  progress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
        let subtitles: [Subtitle]
        var trackLanguage: String? = choice.language

        switch choice {
        case .external(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "sup" {
                subtitles = try PGS(url).subtitles
            } else {
                let base = url.deletingPathExtension()
                let vob = try VobSub(base.appendingPathExtension("sub"), base.appendingPathExtension("idx"))
                subtitles = vob.subtitles
                trackLanguage = vob.language ?? trackLanguage
            }
        case .embedded(let stream):
            // ffprobe stream order and Matroska track order both follow the track entries, so the n-th
            // picture-subtitle stream is the n-th PGS/VobSub track entry.
            let pictureStreams = info.subtitles.filter { $0.codec == "hdmv_pgs_subtitle" || $0.codec == "dvd_subtitle" }
            guard let position = pictureStreams.firstIndex(where: { $0.index == stream.index }) else { throw Failure.trackNotFound }
            let mkv = try MKVTrackParser(filePath: media.path)
            try mkv.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"], onlyAt: position)
            guard position < mkv.tracks.count else { throw Failure.trackNotFound }
            let track = mkv.tracks[position]
            // A track of the other kind in that place means the two lists disagree; better no OCR than
            // another track's text kept under this one's name.
            guard (track.codecID == "S_HDMV/PGS") == (stream.codec == "hdmv_pgs_subtitle") else { throw Failure.trackNotFound }
            trackLanguage = track.language ?? trackLanguage
            if track.codecID == "S_HDMV/PGS" {
                subtitles = try track.trackData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in try PGS(buffer) }.subtitles
            } else {
                subtitles = try track.trackData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in try VobSub(buffer, track.idxData ?? "") }.subtitles
            }
        }
        guard !subtitles.isEmpty else { throw Failure.nothingRecognized }
        try Task.checkCancellation()

        var languages = [Lang.normalize(trackLanguage), Lang.normalize(preferredLanguage), "en"].compactMap { $0 }
        languages = languages.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        // One reading at a time uses Vision: each builds its recognizer on its first picture and drops
        // it after its last, and two of those overlapping (two episodes started together) corrupt each
        // other. Reading the files above can overlap; it doesn't touch Vision.
        //
        // The pictures go through VNRecognizeTextRequest (`forceOldAPI`), not macOS 15's
        // RecognizeTextRequest. Performing the newer request from several tasks at once crashes inside
        // Vision (on macOS 26.2, about every other run of a few hundred pictures read seven at a time,
        // even with a lone first picture to build the engine), while the older one, a request and
        // handler per picture on a queue of its own, survived thousands, and was about three times
        // faster than the newer one read one picture at a time.
        await visionTurns.take()
        let result: macSubtitleOCRResult
        do {
            defer { visionTurns.give() }
            try Task.checkCancellation()
            result = try await SubtitleProcessor(
                for: subtitles, from: 0,
                withOptions: false, false, languages.joined(separator: ","), nil, false, false, false, true,
                NSTemporaryDirectory(), max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
                .process(progress: progress)
        }
        let ordered = result.srt.filter { !($0.text ?? "").isEmpty }
        guard !ordered.isEmpty else { throw Failure.nothingRecognized }
        // SRT puts the cues in time order and fixes up missing or overlapping end times.
        return SRT(subtitles: ordered).encoded()
    }
}

/// Turns at Vision for readings, first come first served.
private let visionTurns = Turns()

private final class Turns: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if taken {
                waiting.append(continuation)
                lock.unlock()
            } else {
                taken = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func give() {
        lock.lock()
        if waiting.isEmpty {
            taken = false
            lock.unlock()
        } else {
            let next = waiting.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Passes OCR progress on to everyone waiting for one reading. Called from the reading's own task, in
/// order, so a waiter never sees the count go backward.
private final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (Int, Int) -> Void] = [:]

    func add(_ id: UUID, _ handler: @escaping @Sendable (Int, Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = handler
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = nil
    }

    func send(_ done: Int, _ total: Int) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        current.forEach { $0(done, total) }
    }
}

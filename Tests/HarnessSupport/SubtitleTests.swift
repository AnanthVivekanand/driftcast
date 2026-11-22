import AppKit
import Foundation
import zlib

// Harness checks for subtitles: the OCR readers, sidecar files, languages, OpenSubtitles.
// Uses check(_:_:), spin, await_ and fetch from Helpers.swift, and the global mediaDir (the
// test media folder, from the command line) that harness.swift defines.
func subtitleTests() {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("driftcast-subtitle-tests", isDirectory: true)
    try? fm.removeItem(at: work)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    languageChecks()
    sidecarChecks(work)
    srtChecks()
    pgsParserChecks(work)
    vobSubParserChecks(work)
    mkvParserChecks(work)
    openSubtitlesChecks()
    loaderChecks(work)
    ocrChecks(work)
}

// MARK: - Languages and file names

private func languageChecks() {
    check(Lang.matches("nor", "nb") && Lang.matches("nob", "no") && Lang.matches("nno", "nor") && Lang.matches("nb", "nn"),
          "Norwegian: nor, no, nb, nob, nn and nno all match each other")
    check(!Lang.matches("nb", "da") && !Lang.matches("no", "sv"), "Norwegian doesn't match Danish or Swedish")
    check(Lang.normalize("kan") == "kn" && Lang.normalize("gle") == "ga" && Lang.normalize("guj") == "gu",
          "3-letter codes missing from the table come from the system: kan \(Lang.normalize("kan") ?? "nil"), gle \(Lang.normalize("gle") ?? "nil")")
    check(Lang.name("yue") != nil && Lang.normalize("cmn") == "zh", "Cantonese has a name (\(Lang.name("yue") ?? "nil")), Mandarin is Chinese")
    check(Lang.normalize("und") == nil && Lang.normalize("zxx") == nil && Lang.normalize("mul") == nil && Lang.normalize("qaa") == nil,
          "und, zxx, mul and qaa name no language")
    check(Lang.isLanguageCode("en") && Lang.isLanguageCode("ger") && !Lang.isLanguageCode("up") && !Lang.isLanguageCode("1080p"),
          "isLanguageCode as before (up and 1080p rejected)")

    func language(_ path: String) -> String? { SubtitleChoice.external(URL(fileURLWithPath: path)).language }
    let cases: [(String, String?)] = [
        ("/v/Movie.en.forced.srt", "en"), ("/v/Movie.eng.srt", "eng"), ("/v/Movie.English.srt", "en"),
        ("/v/Movie.pt-BR.srt", "pt-BR"), ("/v/Movie.zh-Hans.srt", "zh-Hans"), ("/v/Movie.pt_BR.srt", "pt-BR"),
        ("/v/Movie.es-419.srt", "es-419"), ("/v/Movie.No-Way.srt", nil),
        ("/v/Movie.en.12345.srt", "en"), ("/v/Movie.pt-BR.forced.98765.srt", "pt-BR"),
        ("/v/Movie.en.sdh.srt", "en"), ("/v/Movie.en.hi.srt", "en"), ("/v/Movie.hi.srt", "hi"), ("/v/Movie.sdh.srt", nil),
        ("/v/Movie.English (SDH).srt", "en"), ("/v/Movie.Español.srt", "es"),
        ("/v/Sin.City.2005.1080p.BluRay.x264-GRP.srt", nil), ("/v/Ice.Age.2002.srt", nil), ("/v/No.Time.To.Die.2021.srt", nil),
        ("/v/El.Camino.2019.srt", nil), ("/v/Mr.Robot.S01E01.srt", nil), ("/v/It.2017.srt", nil), ("/v/Up.srt", nil),
        ("/v/Ice.srt", nil), ("/v/Rocky.II.srt", nil), ("/v/The.Black.Cat.srt", nil), ("/v/Movie.ger.srt", "ger"), ("/v/How.To.Train.Your.Dragon.2010.1080p.srt", nil),
        ("/v/Subs/2_English.srt", "en"), ("/v/Subs/Show.S01E01/3_French.srt", "fr"), ("/v/Subs/English.srt", "en"),
        ("/v/Other/English.srt", nil),
    ]
    for (path, expected) in cases {
        let found = language(path)
        check(found == expected, "language of \((path as NSString).lastPathComponent): \(found ?? "none") (want \(expected ?? "none"))")
    }

    let sidecars: [(String, String, Bool)] = [
        ("Movie.srt", "Movie", true), ("Movie.en.srt", "Movie", true), ("movie.EN.forced.srt", "Movie", true),
        ("Movie.English.srt", "Movie", true), ("Movie_en.srt", "Movie", true), ("Movie - English.srt", "Movie", true),
        ("Movie.forced.srt", "Movie", true), ("Movie.pt-BR.srt", "Movie", true), ("Movie.mkv.srt", "Movie", true),
        ("Aliens.en.srt", "Alien", false), ("Show.S01E10.en.srt", "Show.S01E1", false), ("Dune Part Two.en.srt", "Dune", false),
        ("Alien.Resurrection.srt", "Alien", false), ("Alien 3.srt", "Alien", false), ("Show 10.srt", "Show 1", false),
    ]
    for (file, video, expected) in sidecars {
        let name = (file as NSString).deletingPathExtension
        check(SubtitleChoice.isSidecarName(name, of: video) == expected,
              "\(file) \(expected ? "belongs" : "doesn't belong") to \(video)")
    }
}

private func sidecarChecks(_ work: URL) {
    let fm = FileManager.default
    func touch(_ url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("1\n00:00:01,000 --> 00:00:02,000\nx\n".utf8).write(to: url)
    }
    func names(_ urls: [URL], relativeTo dir: URL) -> [String] {
        let base = dir.resolvingSymlinksInPath().path
        return urls.map { String($0.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
    }

    // A film folder as releases ship it: the subtitles in Subs, named only by language.
    let film = work.appendingPathComponent("Film.2019.1080p.BluRay.x264-GRP", isDirectory: true)
    let filmVideo = film.appendingPathComponent("Film.2019.1080p.BluRay.x264-GRP.mp4")
    for path in ["Film.2019.1080p.BluRay.x264-GRP.mp4", "Film.2019.1080p.BluRay.x264-GRP.en.srt", "Subs/2_English.srt",
                 "Subs/3_French.srt", "Subs/notes.txt", "Other.Film.en.srt"] {
        touch(film.appendingPathComponent(path))
    }
    let filmFiles = names(SubtitleChoice.externalFiles(near: filmVideo), relativeTo: film)
    check(filmFiles == ["Film.2019.1080p.BluRay.x264-GRP.en.srt", "Subs/2_English.srt", "Subs/3_French.srt"],
          "film: its own sidecar and everything in Subs, nothing else: \(filmFiles)")
    let filmLanguages = SubtitleChoice.externalFiles(near: filmVideo).map { SubtitleChoice.external($0).language ?? "none" }
    check(filmLanguages == ["en", "en", "fr"], "film: languages read from the Subs names: \(filmLanguages)")

    // A season folder: each episode's subtitles in a Subs folder named after it.
    let season = work.appendingPathComponent("Show.S01", isDirectory: true)
    for path in ["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E10.mkv", "Show.S01E1.mkv", "Show.S01E10.en.srt",
                 "Subs/Show.S01E01/2_English.srt", "Subs/Show.S01E01/3_Spanish.srt", "Subs/Show.S01E02/2_English.srt",
                 "Subs/stray.en.srt"] {
        touch(season.appendingPathComponent(path))
    }
    let episode1 = names(SubtitleChoice.externalFiles(near: season.appendingPathComponent("Show.S01E01.mkv")), relativeTo: season)
    check(episode1 == ["Subs/Show.S01E01/2_English.srt", "Subs/Show.S01E01/3_Spanish.srt"],
          "episode 1: only its own Subs folder (\(episode1))")
    let episode2 = names(SubtitleChoice.externalFiles(near: season.appendingPathComponent("Show.S01E02.mkv")), relativeTo: season)
    check(episode2 == ["Subs/Show.S01E02/2_English.srt"], "episode 2: its own (\(episode2))")
    let shortName = names(SubtitleChoice.externalFiles(near: season.appendingPathComponent("Show.S01E1.mkv")), relativeTo: season)
    check(shortName.isEmpty, "Show.S01E1 doesn't take Show.S01E10's subtitle or a stray in a shared Subs folder (\(shortName))")
}

// MARK: - SRT

private func srtChecks() {
    func cue(_ index: Int, _ start: Double, _ end: Double?, _ text: String) -> Subtitle {
        Subtitle(index: index, text: text, startTimestamp: start, endTimestamp: end)
    }
    // As the OCR hands them over: blank cue 2 already dropped, so the numbers have a gap.
    let text = SRT(subtitles: [cue(1, 1, nil, "one"), cue(3, 3, 10, "three"), cue(4, 12, nil, "four"),
                               cue(5, 20, nil, "five")]).encoded()
    let cues = WebVTT.parse(text)
    check(cues.map(\.text) == ["one", "three", "four", "five"] && text.hasPrefix("1\n") && text.contains("\n4\n"),
          "SRT numbers cues 1 to 4 whatever their own numbers")
    check(cues.count == 4 && abs(cues[0].end - 2.9) < 0.01,
          "a cue with no end runs to just before the next one, found by place, not number (\(cues.first?.end ?? -1))")
    check(cues.count == 4 && abs(cues[1].end - 10) < 0.01, "a 7 second line keeps its own end (\(cues.count > 1 ? cues[1].end : -1))")
    check(cues.count == 4 && abs(cues[2].end - 17) < 0.01 && abs(cues[3].end - 25) < 0.01,
          "a cue with no end and room after it gets 5 seconds")
    let crowded = WebVTT.parse(SRT(subtitles: [cue(1, 5, 8, "a"), cue(2, 5.05, 9, "b"), cue(3, 2, 3, "early")]).encoded())
    check(crowded.map(\.text) == ["early", "a", "b"] && crowded.allSatisfy { $0.end >= $0.start },
          "cues come out in time order, none ending before it starts")
}

// MARK: - Building test pictures

private typealias Segment = (type: UInt8, payload: [UInt8])

private func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

/// Text drawn white on clear, as palette indexes: 1 for text, 0 for clear.
private func renderText(_ text: String) -> (width: Int, height: Int, pixels: [UInt8]) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    let width = Int(size.width.rounded(.up)) + 16, height = Int(size.height.rounded(.up)) + 16
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    string.draw(at: NSPoint(x: 8, y: 8))
    NSGraphicsContext.restoreGraphicsState()
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0 ..< height {
        for x in 0 ..< width where rep.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
            pixels[y * width + x] = 1
        }
    }
    return (width, height, pixels)
}

private func pgsRLE(_ width: Int, _ height: Int, _ pixels: [UInt8]) -> [UInt8] {
    var data: [UInt8] = []
    for y in 0 ..< height {
        var x = 0
        while x < width {
            let color = pixels[y * width + x]
            var run = 1
            while x + run < width, pixels[y * width + x + run] == color, run < 16383 { run += 1 }
            if color == 0 {
                data += run < 64 ? [0, UInt8(run)] : [0, 0x40 | UInt8(run >> 8), UInt8(run & 0xFF)]
            } else if run == 1 {
                data.append(color)
            } else if run < 64 {
                data += [0, 0x80 | UInt8(run), color]
            } else {
                data += [0, 0xC0 | UInt8(run >> 8), UInt8(run & 0xFF), color]
            }
            x += run
        }
        data += [0, 0]
    }
    return data
}

private struct PGSObject {
    var id: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(id: Int = 0, text: String, y: Int = 600) {
        let (w, h, px) = renderText(text)
        self.id = id
        self.x = max(0, (1280 - w) / 2)
        self.y = y
        width = w
        height = h
        pixels = px
    }
}

/// A display set that shows `objects`: composition, window, palette (0 clear, 1 white), the objects
/// (split into fragments of `fragmentSize` bytes if given) and the end segment.
private func pgsShow(_ objects: [PGSObject], composition: Int, fragmentSize: Int? = nil,
                     brokenRLE: Bool = false) -> [Segment] {
    var pcs = u16(1280) + u16(720) + [0x10] + u16(composition) + [0x80, 0, 0, UInt8(objects.count)]
    for object in objects { pcs += u16(object.id) + [0, 0] + u16(object.x) + u16(object.y) }
    var segments: [Segment] = [(0x16, pcs)]
    var wds: [UInt8] = [UInt8(objects.count)]
    for (i, object) in objects.enumerated() { wds += [UInt8(i)] + u16(object.x) + u16(object.y) + u16(object.width) + u16(object.height) }
    segments.append((0x17, wds))
    segments.append((0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255]))
    for object in objects {
        var rle = pgsRLE(object.width, object.height, object.pixels)
        if brokenRLE { rle = Array(rle.prefix(rle.count / 3)) }
        let length = rle.count + 4
        let body = [UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + u16(object.width) + u16(object.height) + rle
        let size = fragmentSize ?? body.count
        let pieces = stride(from: 0, to: body.count, by: size).map { Array(body[$0 ..< min($0 + size, body.count)]) }
        for (i, piece) in pieces.enumerated() {
            let flag: UInt8 = (i == 0 ? 0x80 : 0) | (i == pieces.count - 1 ? 0x40 : 0)
            segments.append((0x15, u16(object.id) + [0, flag] + piece))
        }
    }
    segments.append((0x80, []))
    return segments
}

private func pgsClear(composition: Int) -> [Segment] {
    [(0x16, u16(1280) + u16(720) + [0x10] + u16(composition) + [0x00, 0, 0, 0]), (0x80, [])]
}

private func supData(_ sets: [(time: Double, segments: [Segment])]) -> Data {
    var data = Data()
    for set in sets {
        let t = UInt32(set.time * 90000)
        for segment in set.segments {
            data += [0x50, 0x47, UInt8(t >> 24), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF), 0, 0, 0, 0, segment.type]
            data += u16(segment.payload.count) + segment.payload
        }
    }
    return data
}

/// A display set as Matroska stores it: the segments without their "PG" headers.
private func pgsFrame(_ segments: [Segment]) -> Data {
    Data(segments.flatMap { [$0.type] + u16($0.payload.count) + $0.payload })
}

/// Display sets for cues: each shown at its start and cleared at its end.
private func pgsSets(_ cues: [(start: Double, end: Double, text: String)]) -> [(time: Double, segments: [Segment])] {
    cues.enumerated().flatMap { i, cue in
        [(cue.start, pgsShow([PGSObject(text: cue.text)], composition: 2 * i)), (cue.end, pgsClear(composition: 2 * i + 1))]
    }
}

private func subtitles(_ data: Data) throws -> [Subtitle] {
    try data.withUnsafeBytes { try PGS($0).subtitles }
}

// MARK: - VobSub pictures

/// A DVD subpicture unit for a 2 color picture: color 0 clear, color 1 opaque white (index file
/// colors 0 and 1). It comes on at once and goes off after `stopTicks` (units of 1024/90000 s).
private func vobSubUnit(_ text: String, x: Int = 100, y: Int = 400, stopTicks: Int) -> [UInt8] {
    let (width, height, pixels) = renderText(text)
    func field(_ first: Int) -> [UInt8] {
        var nibbles: [UInt8] = []
        func put(_ value: Int, _ count: Int) { for i in (0 ..< count).reversed() { nibbles.append(UInt8((value >> (4 * i)) & 0xF)) } }
        for row in stride(from: first, to: height, by: 2) {
            var column = 0
            while column < width {
                let color = Int(pixels[row * width + column])
                var run = 1
                while column + run < width, pixels[row * width + column + run] == pixels[row * width + column], run < 255 { run += 1 }
                if column + run == width {
                    put(color, 4) // to the end of the line
                } else {
                    let code = run << 2 | color
                    put(code, run < 4 ? 1 : run < 16 ? 2 : run < 64 ? 3 : 4)
                }
                column += run
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
        }
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }
    let even = field(0), odd = field(1)
    let control = 4 + even.count + odd.count
    let x2 = x + width - 1, y2 = y + height - 1
    let area: [UInt8] = [UInt8(x >> 4), UInt8((x & 0xF) << 4 | x2 >> 8), UInt8(x2 & 0xFF),
                         UInt8(y >> 4), UInt8((y & 0xF) << 4 | y2 >> 8), UInt8(y2 & 0xFF)]
    let secondSequence = control + 24
    // Colors: 0 is index file color 0 (clear), 1 is color 1 (opaque white). Then area, field offsets, start.
    var first: [UInt8] = [0, 0] + u16(secondSequence)
    first += [0x03, 0x00, 0x10, 0x04, 0x00, 0xF0, 0x05]
    first += area
    first += [0x06] + u16(4) + u16(4 + even.count)
    first += [0x01, 0xFF]
    let second: [UInt8] = u16(stopTicks) + u16(secondSequence) + [0x02, 0xFF]
    let body = even + odd + first + second
    return u16(4 + body.count) + u16(control) + body
}

private func ptsBytes(_ pts: UInt64) -> [UInt8] {
    [0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF), UInt8(((pts >> 14) & 0xFE) | 1),
     UInt8((pts >> 7) & 0xFF), UInt8(((pts << 1) & 0xFE) | 1)]
}

/// The program stream packs a .sub file holds a unit in, each filled to 2048 bytes with a padding packet.
private func vobSubPacks(_ unit: [UInt8], time: Double, substream: UInt8) -> [UInt8] {
    var out: [UInt8] = []
    var rest = unit[...]
    var first = true
    while !rest.isEmpty {
        let header: [UInt8] = first ? [0x81, 0x80, 0x05] + ptsBytes(UInt64(time * 90000)) : [0x81, 0x00, 0x00]
        let room = 2048 - 14 - 6 - header.count - 1 - 6
        let payload = rest.prefix(room)
        rest = rest.dropFirst(payload.count)
        var pack: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8, 0, 0, 1, 0xBD]
        pack += u16(header.count + 1 + payload.count) + header + [substream] + payload
        let padding = 2048 - pack.count - 6
        pack += [0, 0, 1, 0xBE] + u16(padding) + [UInt8](repeating: 0xFF, count: padding)
        out += pack
        first = false
    }
    return out
}

private func indexTime(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded())
    return String(format: "%02d:%02d:%02d:%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
}

private let vobSubPalette = "palette: 000000, ffffff, " + Array(repeating: "808080", count: 14).joined(separator: ", ")

// MARK: - Building Matroska files

private func idBytes(_ id: UInt32) -> [UInt8] {
    id > 0xFFFFFF ? [UInt8(id >> 24), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
        : id > 0xFFFF ? [UInt8(id >> 16), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
        : id > 0xFF ? [UInt8(id >> 8), UInt8(id & 0xFF)] : [UInt8(id)]
}

private func element(_ id: UInt32, _ payload: Data, unknownSize: Bool = false) -> Data {
    var data = Data(idBytes(id))
    if unknownSize {
        data += [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    } else {
        data += [0x01] + stride(from: 48, through: 0, by: -8).map { UInt8((payload.count >> $0) & 0xFF) }
    }
    return data + payload
}

private func uintElement(_ id: UInt32, _ value: UInt64) -> Data {
    var bytes: [UInt8] = []
    var value = value
    repeat { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 } while value > 0
    return element(id, Data(bytes))
}

private func stringElement(_ id: UInt32, _ text: String) -> Data { element(id, Data(text.utf8)) }

private struct TestTrack {
    var number: Int
    var codec = "S_HDMV/PGS"
    var language: String? = "eng"
    var codecPrivate: Data?
    /// ContentCompAlgo, ContentCompSettings and ContentEncodingScope.
    var packing: (algorithm: UInt64, settings: Data?, scope: UInt64)?
}

private struct TestBlock {
    var track: Int
    var relative: Int16 = 0
    var frame: Data
    var inGroup = false
    var laced = false
}

private func makeMKV(_ tracks: [TestTrack], _ clusters: [(time: UInt64, blocks: [TestBlock])], unknownSizes: Bool = false) -> Data {
    let header = element(0x1A45_DFA3, stringElement(0x4282, "matroska") + uintElement(0x4287, 4) + uintElement(0x4285, 2))
    var entries = Data()
    for track in tracks {
        var entry = uintElement(0xD7, UInt64(track.number)) + uintElement(0x73C5, UInt64(track.number))
            + uintElement(0x83, 0x11) + stringElement(0x86, track.codec)
        if let language = track.language { entry += stringElement(0x22B59C, language) }
        if let codecPrivate = track.codecPrivate { entry += element(0x63A2, codecPrivate) }
        if let packing = track.packing {
            var compression = uintElement(0x4254, packing.algorithm)
            if let settings = packing.settings { compression += element(0x4255, settings) }
            let encoding = uintElement(0x5031, 0) + uintElement(0x5032, packing.scope) + uintElement(0x5033, 0)
                + element(0x5034, compression)
            entry += element(0x6D80, element(0x6240, encoding))
        }
        entries += element(0xAE, entry)
    }
    var body = element(0x1549_A966, uintElement(0x2A_D7B1, 1_000_000)) + element(0x1654_AE6B, entries)
    for cluster in clusters {
        var content = uintElement(0xE7, cluster.time)
        for block in cluster.blocks {
            let relative = UInt16(bitPattern: block.relative)
            let head = Data([0x80 | UInt8(block.track), UInt8(relative >> 8), UInt8(relative & 0xFF)])
            if block.inGroup {
                content += element(0xA0, element(0xA1, head + [block.laced ? 0x02 : 0x00] + block.frame))
            } else {
                content += element(0xA3, head + [block.laced ? 0x82 : 0x80] + block.frame)
            }
        }
        body += element(0x1F43_B675, content, unknownSize: unknownSizes)
    }
    return header + element(0x1853_8067, body, unknownSize: unknownSizes)
}

private func zlibCompress(_ data: Data) -> Data {
    var length = compressBound(uLong(data.count))
    var out = [UInt8](repeating: 0, count: Int(length))
    let input = [UInt8](data)
    precondition(compress2(&out, &length, input, uLong(input.count), 9) == Z_OK)
    return Data(out.prefix(Int(length)))
}

/// A PGS track in Matroska: one cluster per display set, at the set's time.
private func pgsClusters(_ cues: [(start: Double, end: Double, text: String)], track: Int = 1,
                         pack: (Data) -> Data = { $0 }) -> [(time: UInt64, blocks: [TestBlock])] {
    pgsSets(cues).map { set in (UInt64(set.time * 1000), [TestBlock(track: track, frame: pack(pgsFrame(set.segments)))]) }
}

/// Parses an MKV's picture tracks on a thread of its own and waits at most `seconds` for it, so a
/// reader that loops forever fails the check instead of hanging the harness.
private func parseMKV(_ url: URL, onlyAt position: Int? = nil, within seconds: Double = 20) -> Result<[MKVTrack], Error>? {
    let box = ResultBox()
    Thread.detachNewThread {
        let result = Result { () throws -> [MKVTrack] in
            let parser = try MKVTrackParser(filePath: url.path)
            try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"], onlyAt: position)
            return parser.tracks
        }
        box.set(result)
    }
    spin(seconds) { box.get() != nil }
    return box.get()
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[MKVTrack], Error>?
    func set(_ result: Result<[MKVTrack], Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<[MKVTrack], Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - PGS

private func pgsParserChecks(_ work: URL) {
    let cues: [(start: Double, end: Double, text: String)] = [(1, 4, "First line here"), (6, 13, "A line held for seven seconds"),
                                                              (15, 17, "Last line")]
    let plain = supData(pgsSets(cues))
    let parsed = (try? subtitles(plain)) ?? []
    check(parsed.count == 3 && parsed.map { $0.startTimestamp ?? -1 } == [1, 6, 15] && parsed.map { $0.endTimestamp ?? -1 } == [4, 13, 17],
          "PGS: three cues with their own start and end times (\(parsed.map { "\($0.startTimestamp ?? -1)-\($0.endTimestamp ?? -1)" }))")

    // Two objects in one display set (a top and a bottom line), then more cues after it.
    var top = PGSObject(id: 0, text: "Top line", y: 40)
    top.x = 200
    var bottom = PGSObject(id: 1, text: "Bottom line here", y: 600)
    bottom.x = 300
    let twoObjects = supData([(1, pgsShow([top, bottom], composition: 0)), (3, pgsClear(composition: 1))]
        + pgsSets([(5, 7, "After the pair"), (8, 9, "And one more")]).map { (time: $0.time, segments: $0.segments) })
    let pair = (try? subtitles(twoObjects)) ?? []
    let width = max(top.x + top.width, bottom.x + bottom.width) - top.x
    let height = bottom.y + bottom.height - top.y
    check(pair.count == 3 && pair.first?.imageWidth == width && pair.first?.imageHeight == height
          && pair.map { $0.startTimestamp ?? -1 } == [1, 5, 8],
          "PGS: a display set with two objects is one picture holding both (\(pair.first?.imageWidth ?? 0)x\(pair.first?.imageHeight ?? 0), want \(width)x\(height)), and the cues after it are still read (\(pair.count))")

    // One object sent in three fragments.
    let fragmented = supData([(2, pgsShow([PGSObject(text: "Sent in three pieces")], composition: 0, fragmentSize: 1500)),
                              (4, pgsClear(composition: 1))])
    let segmentsSent = pgsShow([PGSObject(text: "Sent in three pieces")], composition: 0, fragmentSize: 1500).filter { $0.type == 0x15 }.count
    let pieces = (try? subtitles(fragmented)) ?? []
    let expected = renderText("Sent in three pieces")
    check(segmentsSent >= 3 && pieces.count == 1 && pieces.first?.imageWidth == expected.width && pieces.first?.imageHeight == expected.height,
          "PGS: an object in \(segmentsSent) fragments is put back together (\(pieces.first?.imageWidth ?? 0)x\(pieces.first?.imageHeight ?? 0))")

    // A picture that can't be decoded costs that picture only.
    let broken = supData([(1, pgsShow([PGSObject(text: "Good one")], composition: 0)), (2, pgsClear(composition: 1)),
                          (3, pgsShow([PGSObject(text: "Broken one")], composition: 2, brokenRLE: true)), (4, pgsClear(composition: 3)),
                          (5, pgsShow([PGSObject(text: "Good again")], composition: 4)), (6, pgsClear(composition: 5))])
    let survived = (try? subtitles(broken))?.map { $0.startTimestamp ?? -1 }
    check(survived == [1, 5], "PGS: a picture with broken image data is skipped, the rest kept (\(survived ?? []))")

    // Garbage between display sets: the reader finds the next header instead of reading image data as one.
    var garbled = supData(Array(pgsSets(cues).prefix(2)))
    garbled += Data((0 ..< 700).map { UInt8(($0 * 37 + 11) & 0xFF) })
    garbled += supData(Array(pgsSets(cues).suffix(4)))
    let resynced = (try? subtitles(garbled))?.map { $0.startTimestamp ?? -1 }
    check(resynced == [1, 6, 15], "PGS: garbage between display sets is stepped over (\(resynced ?? []))")

    // A repeated display set (a fade's palette change) is one cue, not two.
    let repeated = supData([(1, pgsShow([PGSObject(text: "Same picture")], composition: 0)),
                            (2, pgsShow([PGSObject(text: "Same picture")], composition: 1)), (4, pgsClear(composition: 2))])
    let merged = (try? subtitles(repeated)) ?? []
    check(merged.count == 1 && merged.first?.startTimestamp == 1 && merged.first?.endTimestamp == 4,
          "PGS: the same picture shown again at once is one cue from 1 to 4 (\(merged.map { "\($0.startTimestamp ?? -1)-\($0.endTimestamp ?? -1)" }))")

    // Cut short anywhere: never a crash, and never more than was there.
    var cutsOK = true
    for cut in stride(from: 1, to: plain.count, by: max(1, plain.count / 97)) {
        guard let found = try? subtitles(plain.prefix(cut)) else { continue }
        if found.count > 3 { cutsOK = false }
    }
    check(cutsOK, "PGS: a .sup cut short at ~100 places reads without a crash")
    var noise = Data(count: 20000)
    for i in 0 ..< noise.count { noise[i] = UInt8((i * 7919 + i / 13) & 0xFF) }
    noise[0] = 0x50; noise[1] = 0x47; noise[10] = 0x15
    check((try? subtitles(noise)) != nil, "PGS: noise reads as nothing, without a crash")
}

// MARK: - VobSub

private func vobSubParserChecks(_ work: URL) {
    // One language, two pictures; the second sequence's stop command gives each its end.
    let first = vobSubUnit("First DVD line", stopTicks: 220)
    let second = vobSubUnit("Second DVD line", stopTicks: 440)
    let sub1 = vobSubPacks(first, time: 1, substream: 0x20)
    let sub2 = vobSubPacks(second, time: 6, substream: 0x20)
    let subData = Data(sub1 + sub2)
    let index = ["# VobSub index file, v7 (do not modify this line!)", "size: 1280x720", vobSubPalette, "", "langidx: 0",
                 "id: en, index: 0", "timestamp: \(indexTime(1)), filepos: \(String(format: "%09X", 0))",
                 "timestamp: \(indexTime(6)), filepos: \(String(format: "%09X", sub1.count))"]
    let subURL = work.appendingPathComponent("dvd.sub"), idxURL = work.appendingPathComponent("dvd.idx")
    try! subData.write(to: subURL)
    try! index.joined(separator: "\n").write(to: idxURL, atomically: true, encoding: .utf8)
    let vob = try? VobSub(subURL, idxURL)
    let times = vob?.subtitles.map { "\($0.startTimestamp ?? -1)-\(String(format: "%.2f", $0.endTimestamp ?? -1))" } ?? []
    let ends = vob?.subtitles.map { ($0.endTimestamp ?? 0) - ($0.startTimestamp ?? 0) } ?? []
    check(vob?.subtitles.count == 2 && ends.count == 2 && abs(ends[0] - 2.503) < 0.01 && abs(ends[1] - 5.006) < 0.01,
          "VobSub: each picture's end comes from its stop command (\(times))")
    let rendered = renderText("First DVD line")
    check(vob?.subtitles.first?.imageWidth == rendered.width && vob?.subtitles.first?.imageHeight == rendered.height,
          "VobSub: picture size from the display area (\(vob?.subtitles.first?.imageWidth ?? 0)x\(vob?.subtitles.first?.imageHeight ?? 0))")

    // Windows line breaks and two languages; langidx picks French.
    var interleaved: [UInt8] = []
    var english: [(Double, Int)] = [], french: [(Double, Int)] = []
    for (i, time) in [1.0, 2.0, 6.0, 7.0, 12.0].enumerated() {
        let isFrench = i % 2 == 1 || time == 12
        let packs = vobSubPacks(vobSubUnit(isFrench ? "Ligne \(i)" : "Line \(i)", stopTicks: 100), time: time,
                                substream: isFrench ? 0x21 : 0x20)
        if isFrench { french.append((time, interleaved.count)) } else { english.append((time, interleaved.count)) }
        interleaved += packs
    }
    func lines(_ entries: [(Double, Int)]) -> [String] {
        entries.map { "timestamp: \(indexTime($0.0)), filepos: \(String(format: "%09X", $0.1))" }
    }
    let twoLanguages = (["# VobSub index file, v7 (do not modify this line!)", "size: 1280x720", vobSubPalette, "langidx: 1",
                         "id: en, index: 0"] + lines(english) + ["id: fr, index: 1"] + lines(french)).joined(separator: "\r\n")
    let both = try? Data(interleaved).withUnsafeBytes { try VobSub($0, twoLanguages) }
    check(both?.subtitles.map { $0.startTimestamp ?? -1 } == [2, 7, 12],
          "VobSub: a CRLF index with two languages reads only the one langidx names (\(both?.subtitles.map { $0.startTimestamp ?? -1 } ?? []))")
    let viaFile = work.appendingPathComponent("two.idx")
    try! twoLanguages.write(to: viaFile, atomically: true, encoding: .utf8)
    try! Data(interleaved).write(to: work.appendingPathComponent("two.sub"))
    check((try? VobSub(work.appendingPathComponent("two.sub"), viaFile))?.language == "fr", "VobSub: that section's language is the track's")

    // An index that doesn't fit its .sub: offsets past the end and into the middle of a packet, a bare "id:".
    let mismatched = (["# VobSub index file, v7", vobSubPalette, "id:"]
        + ["timestamp: \(indexTime(1)), filepos: \(String(format: "%09X", 5))",
           "timestamp: \(indexTime(2)), filepos: \(String(format: "%09X", 0))",
           "timestamp: \(indexTime(3)), filepos: \(String(format: "%09X", 999_999))",
           "timestamp: \(indexTime(4)), filepos: \(String(format: "%09X", sub1.count + 700))",
           "timestamp: \(indexTime(5)), filepos: \(String(format: "%09X", sub1.count))"]).joined(separator: "\n")
    let kept = try? subData.withUnsafeBytes { try VobSub($0, mismatched) }
    check(kept?.subtitles.map { $0.startTimestamp ?? -1 } == [2, 5],
          "VobSub: pictures the index points at wrongly are skipped, the good ones kept (\(kept?.subtitles.map { $0.startTimestamp ?? -1 } ?? []))")

    var noPaletteError: Error?
    do { _ = try subData.withUnsafeBytes { try VobSub($0, index.filter { !$0.hasPrefix("palette") }.joined(separator: "\n")) } }
    catch { noPaletteError = error }
    check(noPaletteError?.localizedDescription == "The subtitles are damaged or aren't in a form Driftcast can read.",
          "VobSub: an index with no palette is an error a person can read (\(noPaletteError?.localizedDescription ?? "no error"))")

    var cutsOK = true
    for cut in stride(from: 0, to: subData.count, by: 97) {
        if (try? subData.prefix(cut).withUnsafeBytes { try VobSub($0, index.joined(separator: "\n")) })?.subtitles.count ?? 0 > 2 {
            cutsOK = false
        }
    }
    check(cutsOK, "VobSub: a .sub cut short at ~\(subData.count / 97) places reads without a crash")
}

// MARK: - Matroska

private func mkvParserChecks(_ work: URL) {
    let cues: [(start: Double, end: Double, text: String)] = [(1, 4, "Matroska line one"), (6, 9, "Matroska line two"),
                                                              (12, 15, "Matroska line three")]
    func write(_ name: String, _ data: Data) -> URL {
        let url = work.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }
    func starts(_ tracks: [MKVTrack]?, _ index: Int = 0) -> [Double] {
        guard let tracks, index < tracks.count else { return [] }
        return ((try? subtitles(tracks[index].trackData)) ?? []).map { $0.startTimestamp ?? -1 }
    }

    let plainData = makeMKV([TestTrack(number: 1)], pgsClusters(cues))
    let plain = try? parseMKV(write("plain.mkv", plainData))?.get()
    check(starts(plain) == [1, 6, 12], "MKV: PGS track read (\(starts(plain)))")

    // Unknown sizes, as a recording or ffmpeg writing to a pipe leaves them. These used to loop forever.
    let open = parseMKV(write("unknown.mkv", makeMKV([TestTrack(number: 1)], pgsClusters(cues), unknownSizes: true)))
    check(starts(try? open?.get()) == [1, 6, 12], "MKV: Segment and Clusters of unknown size are read to the end (\(open.map { "\($0)" } ?? "timed out"))")
    if let ffmpeg = FFmpeg.ffmpeg {
        let piped = work.appendingPathComponent("piped.mkv")
        FileManager.default.createFile(atPath: piped.path, contents: nil)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", mediaDir.appendingPathComponent("pgs.mkv").path,
                             "-map", "0:s", "-c:s", "copy", "-f", "matroska", "-"]
        process.standardOutput = try! FileHandle(forWritingTo: piped)
        try! process.run()
        process.waitUntilExit()
        let result = parseMKV(piped)
        check(starts(try? result?.get()).count == 3, "MKV: ffmpeg's piped output (Segment of unknown size) is read (\(result.map { "\(starts(try? $0.get()))" } ?? "timed out"))")
    }

    // Cut short anywhere, as a copy still in progress is: ends, never loops or crashes.
    var finished = 0, attempts = 0
    for cut in stride(from: 0, to: plainData.count, by: max(1, plainData.count / 60)) {
        attempts += 1
        if parseMKV(write("cut.mkv", plainData.prefix(cut)), within: 5) != nil { finished += 1 }
    }
    check(finished == attempts, "MKV: a file cut short at \(attempts) places always finishes (\(finished))")

    // Damage: garbage, IDs longer than 4 bytes, sizes near 2^56, blocks past the end, huge times.
    let header = element(0x1A45_DFA3, stringElement(0x4282, "matroska"))
    let track = element(0x1654_AE6B, element(0xAE, uintElement(0xD7, 1) + stringElement(0x86, "S_HDMV/PGS")))
    var noise = Data(count: 65536)
    for i in 0 ..< noise.count { noise[i] = UInt8((i * 2_654_435_761 >> 7) & 0xFF) }
    let damaged: [(String, Data)] = [
        ("noise", noise),
        ("noise after the header", header + noise),
        ("a 5 byte ID", header + element(0x1853_8067, track + Data([0x08, 0x01, 0x02, 0x03, 0x04, 0x81, 0x00]) + noise.prefix(500))),
        ("a size near 2^56", header + element(0x1853_8067, track + Data([0xEC, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]) + noise.prefix(100))),
        ("a block past the end", header + element(0x1853_8067, track + Data([0x1F, 0x43, 0xB6, 0x75, 0x88]) + uintElement(0xE7, 1)
            + Data([0xA3, 0x01, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x81, 0x00, 0x00, 0x80, 0x16]))),
        ("a time of 2^64 - 1", header + element(0x1853_8067, track + element(0x1F43_B675, uintElement(0xE7, UInt64.max)
            + element(0xA3, Data([0x81, 0x7F, 0xFF, 0x80]) + pgsFrame(pgsShow([PGSObject(text: "Late")], composition: 0)))))),
        ("a VobSub entry with no CodecPrivate", header + element(0x1853_8067, element(0x1654_AE6B, element(0xAE, uintElement(0xD7, 1)
            + stringElement(0x86, "S_VOBSUB"))) + element(0x1F43_B675, uintElement(0xE7, 0) + element(0xA3, Data([0x81, 0, 0, 0x80, 0, 4, 0, 4]))))),
        ("track number 0", header + element(0x1853_8067, track + element(0x1F43_B675, uintElement(0xE7, 0) + element(0xA3, Data([0x00, 0x00]))))),
    ]
    for (what, data) in damaged {
        let result = parseMKV(write("damaged.mkv", data), within: 10)
        check(result != nil, "MKV: \(what) ends without a crash or a hang (\(result.map { r in (try? r.get()).map { "\($0.count) tracks" } ?? "error" } ?? "timed out"))")
    }

    // A block just before its cluster's time: its offset is signed.
    let early = makeMKV([TestTrack(number: 1)], [(10000, [TestBlock(track: 1, relative: -40, frame: pgsFrame(pgsShow([PGSObject(text: "Early")], composition: 0)))]),
                                                 (12000, [TestBlock(track: 1, relative: 0, frame: pgsFrame(pgsClear(composition: 1)))])])
    let earlyStart = starts(try? parseMKV(write("early.mkv", early))?.get())
    check(earlyStart == [9.96], "MKV: a block 40 ms before its cluster is at 9.96 s, not 65.5 s late (\(earlyStart))")

    // Two picture tracks: listed in file order, and only the one asked for is read.
    let english = pgsClusters([(1, 2, "English one"), (3, 4, "English two")], track: 3)
    let spanish = pgsClusters([(5, 6, "Spanish only")], track: 5)
    let twoTracks = write("two.mkv", makeMKV([TestTrack(number: 3), TestTrack(number: 5, language: "spa")],
                                             zip(english, spanish).flatMap { [$0, $1] } + english.dropFirst(spanish.count)))
    let all = try? parseMKV(twoTracks)?.get()
    check(all?.map(\.trackNumber) == [3, 5] && all?.map { $0.language ?? "" } == ["eng", "spa"] && starts(all, 0) == [1, 3] && starts(all, 1) == [5],
          "MKV: two picture tracks in file order with their own cues (\(all?.map(\.trackNumber) ?? []))")
    let second = try? parseMKV(twoTracks, onlyAt: 1)?.get()
    check(second?.count == 2 && second?[0].trackData.isEmpty == true && starts(second, 1) == [5],
          "MKV: reading the second picture track reads only it")
    let one = try? parseMKV(write("one.mkv", makeMKV([TestTrack(number: 2)], [])))?.get()
    check(one?.count == 1 && one?.first?.trackData.isEmpty == true, "MKV: a picture track with no blocks is kept, empty, in its place")

    // Packed blocks: zlib (mkvmerge's default) and header stripping.
    let zipped = makeMKV([TestTrack(number: 1, packing: (0, nil, 1))], pgsClusters(cues, pack: zlibCompress))
    let unzipped = try? parseMKV(write("zlib.mkv", zipped))?.get()
    check(unzipped?.first?.trackData == plain?.first?.trackData && starts(unzipped) == [1, 6, 12],
          "MKV: zlib-compressed PGS blocks come out the same as plain ones (\(starts(unzipped)))")
    let stripped = makeMKV([TestTrack(number: 1, packing: (3, Data([0x16]), 1))], pgsClusters(cues, pack: { $0.dropFirst() }))
    let unstripped = try? parseMKV(write("stripped.mkv", stripped))?.get()
    check(unstripped?.first?.trackData == plain?.first?.trackData, "MKV: header-stripped blocks get their header back")
    var refusal: Error?
    do { _ = try parseMKV(write("bzip.mkv", makeMKV([TestTrack(number: 1, packing: (1, nil, 1))], pgsClusters(cues))))?.get() }
    catch { refusal = error }
    check(refusal?.localizedDescription == "These subtitles are packed in a way Driftcast can't read.",
          "MKV: bzip2-packed blocks are refused, so the subtitle is burned in instead (\(refusal.map { "\($0)" } ?? "no error"))")

    // Blocks inside block groups are read; laced blocks are left out.
    var grouped = pgsClusters(cues)
    grouped[0].blocks[0].inGroup = true
    grouped[2].blocks[0].laced = true
    check(starts(try? parseMKV(write("grouped.mkv", makeMKV([TestTrack(number: 1)], grouped)))?.get()) == [1, 12],
          "MKV: a Block in a BlockGroup is read and a laced block skipped")

    // VobSub with zlib on the blocks and on CodecPrivate.
    let header2 = Data(("size: 1280x720\n" + vobSubPalette + "\n").utf8)
    let vobCues: [(Double, String)] = [(2, "DVD in Matroska"), (8, "Second DVD picture")]
    let vobTrack = TestTrack(number: 4, codec: "S_VOBSUB", language: "fre", codecPrivate: zlibCompress(header2), packing: (0, nil, 3))
    let vobClusters = vobCues.map { (UInt64($0.0 * 1000), [TestBlock(track: 4, frame: zlibCompress(Data(vobSubUnit($0.1, stopTicks: 200))), inGroup: true)]) }
    let vobTracks = try? parseMKV(write("vobsub.mkv", makeMKV([vobTrack], vobClusters)))?.get()
    let vob = vobTracks.flatMap { tracks in try? tracks[0].trackData.withUnsafeBytes { try VobSub($0, tracks[0].idxData ?? "") } }
    check(vob?.subtitles.map { $0.startTimestamp ?? -1 } == [2, 8] && vob?.subtitles.first?.imageWidth == renderText("DVD in Matroska").width,
          "MKV: zlib-compressed VobSub (blocks and index) read (\(vob?.subtitles.map { $0.startTimestamp ?? -1 } ?? []))")
}

// MARK: - OpenSubtitles

private func openSubtitlesChecks() {
    // The built-in key file: 32 mask bytes, then the key XORed with them (Scripts/embed-subtitle-key.sh).
    let secret = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789xyz"
    let mask = (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) }
    let masked = Array(secret.utf8).enumerated().map { $0.element ^ mask[$0.offset % 32] }
    let file = Data(mask + masked)
    check(OpenSubtitlesClient.unmask(file) == secret, "OpenSubtitles: the built-in key is read back from its masked file")
    check(file.range(of: Data(secret.utf8)) == nil, "OpenSubtitles: the masked key file doesn't hold the key as plain text")
    check(OpenSubtitlesClient.unmask(Data(mask)) == "" && OpenSubtitlesClient.unmask(Data()) == "",
          "OpenSubtitles: a key file with no key in it gives no key")
    var result = OpenSubtitlesClient.Result(fileID: 4242, release: "Movie.2019", fileName: "x.srt", language: "../../pt-BR",
                                            downloads: 10, hearingImpaired: false, hashMatch: true, title: "Movie")
    let video = URL(fileURLWithPath: "/v/Movie.2019.mkv")
    check(OpenSubtitlesClient.fileName(for: result, video: video) == "Movie.2019.pt-BR.4242.srt",
          "OpenSubtitles: the language in a download's name is cleaned (\(OpenSubtitlesClient.fileName(for: result, video: video)))")
    result.foreignPartsOnly = true
    result.language = "en"
    let forcedName = OpenSubtitlesClient.fileName(for: result, video: video)
    check(forcedName == "Movie.2019.en.forced.4242.srt" && SubtitleChoice.external(URL(fileURLWithPath: "/x/" + forcedName)).isForced
          && SubtitleChoice.external(URL(fileURLWithPath: "/x/" + forcedName)).language == "en",
          "OpenSubtitles: a forced-only download is named and treated as forced English (\(forcedName))")
    var full = result
    full.foreignPartsOnly = false
    full.hashMatch = false
    check(OpenSubtitlesClient.rank(full) > OpenSubtitlesClient.rank(result), "OpenSubtitles: forced-only results rank after full ones")
    // Not a match, but near or far by name.
    let episode = "The.Sopranos.S04E08.1080p.BluRay.x265-RARBG"
    check(ReleaseMatch.closeness("The.Sopranos.S04E08.1080p.BluRay.ReEnc-DeeJayAhmed", to: episode) == 1,
          "OpenSubtitles: a subtitle from the same source as the video is close")
    check(ReleaseMatch.closeness("the.sopranos.s04e08.internal.dvdrip.xvid-runner", to: episode) == -1
          && ReleaseMatch.closeness("The.Sopranos.S04E09.1080p.BluRay.x265-RARBG", to: episode) == -1
          && ReleaseMatch.closeness("Heat.1995.Extended.BluRay.x264-GRP", to: "Heat.1995.1080p.BluRay.x264-GRP") == -1,
          "OpenSubtitles: another source, episode or cut is far")
    check(ReleaseMatch.closeness("\"Sopranos, The\" (1999)", to: episode) == 0
          && ReleaseMatch.closeness("The.Sopranos.S04E08.1080p.BluRay.ReEnc-DeeJayAhmed", to: "The Sopranos S04E08 Copy") == 0,
          "OpenSubtitles: names that give no source are neither close nor far")
    var close = full, unknown = full, far = full, same = full
    close.closeness = 1; far.closeness = -1; same.releaseMatch = true
    close.downloads = 1; unknown.downloads = 50_000; far.downloads = 90_000
    check(OpenSubtitlesClient.rank(same) > OpenSubtitlesClient.rank(close) && OpenSubtitlesClient.rank(close) > OpenSubtitlesClient.rank(unknown)
          && OpenSubtitlesClient.rank(unknown) > OpenSubtitlesClient.rank(far) && OpenSubtitlesClient.rank(far) > OpenSubtitlesClient.rank(result),
          "OpenSubtitles: same release, then same source, then unknown, then another source, then forced-only, whatever the downloads")
    check(OpenSubtitlesClient.notice(of: [unknown, far]) == "No subtitles found for this file name, and none of these are close to it. They may be out of sync."
          && OpenSubtitlesClient.notice(of: [close, unknown]) == "No subtitles found for this exact file name. The first one is close to it."
          && OpenSubtitlesClient.notice(of: [close, close, far]) == "No subtitles found for this exact file name. The first 2 are close to it."
          && OpenSubtitlesClient.notice(of: [same, close]) == nil && OpenSubtitlesClient.notice(of: []) == nil
          && OpenSubtitlesClient.summary(of: [same, close]).hasPrefix("2 found, 1 made for this video."),
          "OpenSubtitles: the search warns when nothing was made for this video, and says whether the first ones are close")
    // The details panel's own lookup: what it says, and how long a lookup is kept.
    check(OnlineSubtitleLookup.describe(same) == "Made for this release, so it should be in sync."
          && OnlineSubtitleLookup.describe(close) == "Close to this file, so it is likely in sync."
          && OnlineSubtitleLookup.describe(unknown) == "For this title, not this file, so it may be out of sync.",
          "OpenSubtitles lookup: the panel says how near the found subtitle is")
    check(OnlineSubtitleLookup.Match(same).found == "Same release found" && OnlineSubtitleLookup.Match(close).found == "Close match found"
          && OnlineSubtitleLookup.Match(unknown).found == "Subtitles found online" && OnlineSubtitleLookup.Match(unknown).tag == "SAME TITLE ONLY",
          "OpenSubtitles lookup: the pill and the tag say how good a match was found")
    check(OnlineSubtitleLookup.isOffered(same) && OnlineSubtitleLookup.isOffered(close) && !OnlineSubtitleLookup.isOffered(unknown)
          && !OnlineSubtitleLookup.isOffered(far),
          "OpenSubtitles lookup: only likely matches are offered, not ones for the same title only")
    var exactResult = unknown; exactResult.hashMatch = true
    check(OnlineSubtitleLookup.Match(exactResult).found == "Exact match found" && OnlineSubtitleLookup.Match(exactResult).tag == "EXACT MATCH",
          "OpenSubtitles lookup: a subtitle made from this file is an exact match")
    let now = Date()
    let foundEntry = OnlineSubtitleLookup.Saved(best: close, count: 3, checked: now.addingTimeInterval(-20 * 86_400))
    let noneEntry = OnlineSubtitleLookup.Saved(best: nil, count: 0, checked: now.addingTimeInterval(-2 * 86_400))
    check(OnlineSubtitleLookup.isFresh(foundEntry, now: now) && OnlineSubtitleLookup.isFresh(noneEntry, now: now)
          && !OnlineSubtitleLookup.isFresh(foundEntry, now: now.addingTimeInterval(11 * 86_400))
          && !OnlineSubtitleLookup.isFresh(noneEntry, now: now.addingTimeInterval(2 * 86_400)),
          "OpenSubtitles lookup: a found subtitle is kept 30 days, \"none\" 3 days")
    let weakEntry = OnlineSubtitleLookup.Saved(best: unknown, count: 9, checked: now.addingTimeInterval(-4 * 86_400))
    check(!OnlineSubtitleLookup.isFresh(weakEntry, now: now),
          "OpenSubtitles lookup: a result not worth offering is looked up again after 3 days")
    check(OnlineSubtitleLookup.menuTitle(close, language: "en") == "Add English Subtitles Found Online (Close Match)",
          "OpenSubtitles lookup: the subtitle menus' item says the language and how good the match is (\(OnlineSubtitleLookup.menuTitle(close, language: "en")))")
    let savedBack = (try? JSONEncoder().encode(["k": foundEntry])).flatMap { try? JSONDecoder().decode([String: OnlineSubtitleLookup.Saved].self, from: $0) }
    check(savedBack?["k"]?.best == close && savedBack?["k"]?.count == 3,
          "OpenSubtitles lookup: a saved lookup reads back as it was written")
    // Which OpenSubtitles result a downloaded file is, so one taken off a video isn't offered again.
    let downloaded = OpenSubtitlesClient.downloadsFolder.appendingPathComponent(OpenSubtitlesClient.fileName(for: full, video: video))
    var forcedOne = full; forcedOne.foreignPartsOnly = true
    let downloadedForced = OpenSubtitlesClient.downloadsFolder.appendingPathComponent(OpenSubtitlesClient.fileName(for: forcedOne, video: video))
    check(OpenSubtitlesClient.fileID(ofDownloaded: downloaded) == full.fileID && OpenSubtitlesClient.fileID(ofDownloaded: downloadedForced) == full.fileID
          && OpenSubtitlesClient.fileID(ofDownloaded: URL(fileURLWithPath: "/v/Movie.2019.en.4242.srt")) == nil
          && OpenSubtitlesClient.fileID(ofDownloaded: OpenSubtitlesClient.downloadsFolder.appendingPathComponent("notes.srt")) == nil,
          "OpenSubtitles: a downloaded file's result number is read from its name, and only in the downloads folder")
    // Within a group, the name nearest the file's comes before a more downloaded one.
    let reward = "Breaking.Bad.S01E01.720p.BluRay.x264-REWARD"
    check(ReleaseMatch.sharedTags("Breaking.Bad.S01.720p.BluRay.X264-REWARD", with: reward) == 4
          && ReleaseMatch.sharedTags("Breaking.Bad.S01E01.BDRIP.x264.Hun.Eng-Krissz", with: reward) == 1
          && ReleaseMatch.sharedTags("Breaking Bad - season 1", with: reward) == 0,
          "OpenSubtitles: shared release words are counted, not the title or the episode")
    check(ReleaseMatch.closeness("Breaking.Bad.S01E01.720p.x264-REWARD", to: reward) == 1
          && ReleaseMatch.closeness("Breaking Bad Season 1 Episode 01 - Pilot", to: reward) == 0,
          "OpenSubtitles: a name with no source is close when it shares the release's other words")
    check(ReleaseMatch.closeness("Breaking.Bad.S01E01.720p.x264", to: "Breaking.Bad.S01E01.720p.x264.mux") == 0
          && ReleaseMatch.closeness("Breaking.Bad.S01E01.720p.mux", to: "Breaking.Bad.S01E01.720p.x264.mux") == 1,
          "OpenSubtitles: a shared resolution and codec alone don't make a subtitle close")
    var near = close, popular = close
    near.sharedTags = 4; near.downloads = 100; popular.sharedTags = 1; popular.downloads = 900_000
    check(OpenSubtitlesClient.order(near) > OpenSubtitlesClient.order(popular) && OpenSubtitlesClient.order(popular) > OpenSubtitlesClient.order(unknown),
          "OpenSubtitles: among close results the nearest name is first, whatever the downloads")
    check(OpenSubtitlesClient.apiLanguages("pt") == "pt-br,pt-pt" && OpenSubtitlesClient.apiLanguages("nb") == "no"
          && OpenSubtitlesClient.apiLanguages("zh") == "zh-cn,zh-tw" && OpenSubtitlesClient.apiLanguages("EN") == "en",
          "OpenSubtitles: language codes as the API lists them")
    check(OpenSubtitlesClient.Failure.noDownloadsLeft(nil).localizedDescription == "No OpenSubtitles downloads are left today."
          && !OpenSubtitlesClient.Failure.noDownloadsLeft(nil).isKeyRefused, "OpenSubtitles: running out of downloads is said plainly")
}

// MARK: - Text subtitles

private func loaderChecks(_ work: URL) {
    let video = work.appendingPathComponent("Loader.mp4")
    let file = work.appendingPathComponent("Loader.en.srt")
    try! "1\n00:00:01,000 --> 00:00:02,000\nOld text\n".write(to: file, atomically: true, encoding: .utf8)
    let before = try? await_ { try await SubtitleLoader.shared.cues(for: .external(file), media: video) }.get()
    try! "1\n00:00:01,000 --> 00:00:02,000\nNew text\n".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
    let after = try? await_ { try await SubtitleLoader.shared.cues(for: .external(file), media: video) }.get()
    check(before?.first?.text == "Old text" && after?.first?.text == "New text",
          "a subtitle file changed while open is read again (\(before?.first?.text ?? "nil") then \(after?.first?.text ?? "nil"))")
}

// MARK: - OCR

private func ocrChecks(_ work: URL) {
    func probe(_ url: URL) -> MediaInfo? { try? await_ { try await MediaProbe.shared.probe(url) }.get() }
    func pictureChoice(_ url: URL, _ info: MediaInfo) -> SubtitleChoice? {
        SubtitleChoice.available(for: MediaItem(url: url), info: info).first { $0.isPicture }
    }
    func ocr(_ url: URL, language: String = "en") -> (choice: SubtitleChoice, info: MediaInfo, result: Result<[SubtitleCue], Error>)? {
        guard let info = probe(url), let choice = pictureChoice(url, info) else { return nil }
        return (choice, info, await_ { try await PictureSubtitleOCR.shared.cues(for: choice, media: url, info: info, preferredLanguage: language) })
    }
    func texts(_ result: Result<[SubtitleCue], Error>?) -> [String] {
        ((try? result?.get()) ?? []).map { $0.text.lowercased() }
    }

    // zlib-compressed PGS, as mkvmerge writes it, with a block just before its cluster's time.
    let cues: [(start: Double, end: Double, text: String)] = [(1, 4, "Hello from a zipped track"), (6, 9, "The second zipped line")]
    var clusters = pgsClusters(cues, pack: zlibCompress)
    clusters[2].blocks[0].relative = -500
    let zipped = work.appendingPathComponent("zipped.mkv")
    try! makeMKV([TestTrack(number: 1, packing: (0, nil, 1))], clusters).write(to: zipped)
    let zippedRead = ocr(zipped)
    let zippedCues = (try? zippedRead?.result.get()) ?? []
    check(texts(zippedRead?.result).count == 2 && texts(zippedRead?.result)[0].contains("zipped track")
          && texts(zippedRead?.result)[1].contains("second zipped") && abs((zippedCues.last?.start ?? 0) - 5.5) < 0.01,
          "OCR of a zlib-compressed PGS track: \(zippedCues.map { "\($0.start) \($0.text)" }) \(zippedRead.map { "\($0.result)" } ?? "no probe")")

    // VobSub made by ffmpeg's own DVD subtitle encoder from the PGS test file.
    if let ffmpeg = FFmpeg.ffmpeg {
        let dvd = work.appendingPathComponent("dvd.mkv")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", mediaDir.appendingPathComponent("pgs.mkv").path,
                             "-map", "0:s", "-c:s", "dvdsub", "-metadata:s:s:0", "language=eng", dvd.path]
        try! process.run()
        process.waitUntilExit()
        let read = ocr(dvd)
        let found = (try? read?.result.get()) ?? []
        // pgs.mkv has its cues at 0, 5 and 11. ffmpeg's encoder gives every picture the longest stop
        // delay there is (it doesn't know the ends), which is read as no end: 5 seconds, or until just
        // before the next cue.
        let times = found.map { String(format: "%.1f-%.1f", $0.start, $0.end) }
        check(found.count == 3 && found[0].text.lowercased().contains("picture subtitle") && found[1].text.lowercased().contains("quick brown fox")
              && times == ["0.0-4.9", "5.0-10.0", "11.0-16.0"],
              "OCR of VobSub in MKV from ffmpeg's encoder: \(zip(times, found).map { "\($0) \($1.text)" }) \(read.map { "\($0.result)" } ?? "")")
        if let read { _ = await_ { await PictureSubtitleOCR.shared.forgetReading(of: read.choice, media: dvd) } }
    }

    // VobSub in MKV, zlib on blocks and CodecPrivate.
    let vobHeader = Data(("size: 1280x720\n" + vobSubPalette + "\n").utf8)
    let vob = work.appendingPathComponent("zipped-dvd.mkv")
    try! makeMKV([TestTrack(number: 1, codec: "S_VOBSUB", codecPrivate: zlibCompress(vobHeader), packing: (0, nil, 3))],
                 [(2000, [TestBlock(track: 1, frame: zlibCompress(Data(vobSubUnit("Read from a DVD picture", stopTicks: 250))), inGroup: true)])])
        .write(to: vob)
    let vobRead = ocr(vob)
    let vobCues = (try? vobRead?.result.get()) ?? []
    check(vobCues.count == 1 && vobCues[0].text.lowercased().contains("dvd picture") && abs(vobCues[0].end - vobCues[0].start - 2.844) < 0.01,
          "OCR of a zlib-compressed VobSub track, ended by its stop command: \(vobCues.map { String(format: "%.3f-%.3f ", $0.start, $0.end) + $0.text }) \(vobRead.map { "\($0.result)" } ?? "")")

    // French: "l" is not turned into "I" just because English is the fallback language.
    let french = work.appendingPathComponent("french.mkv")
    try! makeMKV([TestTrack(number: 1, language: "fre")], pgsClusters([(1, 3, "C'est l'homme de la gare")])).write(to: french)
    let frenchText = texts(ocr(french, language: "fr")?.result).first ?? ""
    check(frenchText.contains("l'homme") || frenchText.contains("l’homme"), "OCR in French keeps l'homme (\(frenchText))")

    // Two episodes with the picture track at the same place, started together: each gets its own text.
    let episode1 = work.appendingPathComponent("Show.S01E01.mkv"), episode2 = work.appendingPathComponent("Show.S01E02.mkv")
    try! makeMKV([TestTrack(number: 1)], pgsClusters([(1, 3, "This is episode one")])).write(to: episode1)
    try! makeMKV([TestTrack(number: 1)], pgsClusters([(1, 3, "Now episode two")])).write(to: episode2)
    if let info1 = probe(episode1), let info2 = probe(episode2), let choice1 = pictureChoice(episode1, info1),
       let choice2 = pictureChoice(episode2, info2) {
        check(choice1.id == choice2.id, "the two episodes' tracks have the same id (\(choice1.id))")
        let both = await_ { () async throws -> ([SubtitleCue], [SubtitleCue]) in
            async let one = PictureSubtitleOCR.shared.cues(for: choice1, media: episode1, info: info1, preferredLanguage: "en")
            async let two = PictureSubtitleOCR.shared.cues(for: choice2, media: episode2, info: info2, preferredLanguage: "en")
            return try await (one, two)
        }
        let pair = try? both.get()
        check(pair?.0.first?.text.lowercased().contains("episode one") == true && pair?.1.first?.text.lowercased().contains("episode two") == true,
              "two videos read at once each get their own subtitles (\(pair.map { "\($0.0.first?.text ?? "") / \($0.1.first?.text ?? "")" } ?? "\(both)"))")
    } else {
        check(false, "the episode files could be probed")
    }

    // Progress, cancel, and forgetting a reading.
    let many = (0 ..< 120).map { (start: Double($0 * 3 + 1), end: Double($0 * 3 + 3), text: "Line number \($0 + 1) of many") }
    let long = work.appendingPathComponent("long.mkv")
    try! makeMKV([TestTrack(number: 1)], pgsClusters(many)).write(to: long)
    if let info = probe(long), let choice = pictureChoice(long, info) {
        let progress = ProgressLog()
        let task = Task { try await PictureSubtitleOCR.shared.cues(for: choice, media: long, info: info, preferredLanguage: "en",
                                                                   progress: { progress.add($0, $1) }) }
        spin(30) { progress.last != nil }
        let canceledAt = Date()
        task.cancel()
        var outcome: Result<[SubtitleCue], Error>?
        Task { outcome = await task.result }
        spin(20) { outcome != nil }
        let stopped = Date().timeIntervalSince(canceledAt)
        let wasCanceled: Bool
        if case .failure(let error)? = outcome { wasCanceled = error is CancellationError } else { wasCanceled = false }
        check(progress.last?.total == 120 && wasCanceled && stopped < 10 && !PictureSubtitleOCR.hasReading(of: choice, media: long),
              "OCR reports progress (\(progress.last.map { "\($0.done)/\($0.total)" } ?? "none")) and stops \(String(format: "%.1f", stopped)) s after its task is canceled, keeping nothing (\(outcome.map { "\($0)" } ?? "still running"))")

        let full = await_ { try await PictureSubtitleOCR.shared.cues(for: choice, media: long, info: info, preferredLanguage: "en",
                                                                     progress: { progress.add($0, $1) }) }
        check((try? full.get())?.count == 120 && progress.last?.done == 120 && PictureSubtitleOCR.hasReading(of: choice, media: long),
              "after a cancel, reading the track again starts afresh and finishes (\((try? full.get())?.count ?? 0) cues)")

        // A reload of the same video asks again at once: it joins the reading under way.
        _ = await_ { await PictureSubtitleOCR.shared.forgetReading(of: choice, media: long) }
        let before = ProgressLog(), after = ProgressLog()
        let leaving = Task { try await PictureSubtitleOCR.shared.cues(for: choice, media: long, info: info, preferredLanguage: "en",
                                                                      progress: { before.add($0, $1) }) }
        spin(30) { (before.last?.done ?? 0) >= 10 }
        leaving.cancel()
        let reload = await_ { try await PictureSubtitleOCR.shared.cues(for: choice, media: long, info: info, preferredLanguage: "en",
                                                                       progress: { after.add($0, $1) }) }
        check((try? reload.get())?.count == 120 && (after.first?.done ?? 0) > 10,
              "a reload right after a cancel joins the reading under way (its first progress: \(after.first.map { "\($0.done)/\($0.total)" } ?? "none"))")
        _ = await_ { await PictureSubtitleOCR.shared.forgetReading(of: choice, media: long) }
        check(!PictureSubtitleOCR.hasReading(of: choice, media: long), "Read Subtitles Again: the kept reading is forgotten")
    } else {
        check(false, "the long test file could be probed")
    }

    // A track with nothing readable fails, and the failure is remembered for the run.
    let blank = work.appendingPathComponent("blank.mkv")
    let empty = PGSObject(id: 0, text: " ")
    try! makeMKV([TestTrack(number: 1)], [(1000, [TestBlock(track: 1, frame: pgsFrame(pgsShow([empty], composition: 0)))])]).write(to: blank)
    if let info = probe(blank), let choice = pictureChoice(blank, info) {
        let first = await_ { try await PictureSubtitleOCR.shared.cues(for: choice, media: blank, info: info, preferredLanguage: "en") }
        let start = Date()
        let again = await_ { try await PictureSubtitleOCR.shared.cues(for: choice, media: blank, info: info, preferredLanguage: "en") }
        let quick = Date().timeIntervalSince(start) < 0.5
        var message = ""
        if case .failure(let error) = again { message = error.localizedDescription }
        check(quick && message == "No text was recognized in the subtitles." && (try? first.get()) == nil,
              "a track with no text fails once and is not read again this run (\(message))")
        _ = await_ { await PictureSubtitleOCR.shared.forgetReading(of: choice, media: blank) }
    }
    for url in [zipped, vob, french, episode1, episode2] {
        if let info = probe(url), let choice = pictureChoice(url, info) {
            _ = await_ { await PictureSubtitleOCR.shared.forgetReading(of: choice, media: url) }
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var earliest: (done: Int, total: Int)?
    private var latest: (done: Int, total: Int)?
    func add(_ done: Int, _ total: Int) {
        lock.lock()
        if earliest == nil { earliest = (done, total) }
        latest = (done, total)
        lock.unlock()
    }
    var first: (done: Int, total: Int)? { lock.lock(); defer { lock.unlock() }; return earliest }
    var last: (done: Int, total: Int)? { lock.lock(); defer { lock.unlock() }; return latest }
}

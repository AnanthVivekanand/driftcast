import AppKit
import Foundation

/// The picture shown for a few seconds when a video starts on this Mac or an AirPlay TV: the
/// poster on the left and the title with what is known about the film on the right, on black.
/// Drawn here rather than by ffmpeg, which has no text filter in every build.
enum TitleCard {
    static let seconds = 5.0

    /// A JPEG of `size` (made even, at least 320 x 180) for the encoder.
    static func render(poster: Data?, title: String, details: MovieDetails?, size: CGSize) -> Data? {
        let width = max(320, Int(size.width) / 2 * 2), height = max(180, Int(size.height) / 2 * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let w = CGFloat(width), h = CGFloat(height)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        var textLeft = w * 0.08
        if let poster, let image = NSImage(data: poster), image.size.width > 0, image.size.height > 0 {
            let scale = min(h * 0.72 / image.size.height, w * 0.34 / image.size.width)
            let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: w * 0.08, y: (h - drawn.height) / 2, width: drawn.width, height: drawn.height)
            // A soft shadow behind the poster, then the poster itself with rounded corners.
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = h * 0.025
            shadow.shadowOffset = NSSize(width: 0, height: -h * 0.01)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.set()
            NSColor(white: 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: h * 0.01, yRadius: h * 0.01).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: h * 0.01, yRadius: h * 0.01).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            textLeft = rect.maxX + w * 0.05
        }

        // The words, top to bottom, with their size and colour.
        struct Line {
            var text: String
            var size: CGFloat
            var color: NSColor
            var weight: NSFont.Weight
            var maxLines: Int
        }
        let white = NSColor.white, grey = NSColor(white: 0.72, alpha: 1)
        let gold = NSColor(red: 1, green: 0.84, blue: 0.4, alpha: 1)
        var lines: [Line] = []
        if let d = details, d.isEpisode {
            lines.append(Line(text: d.showTitle ?? d.title, size: h * 0.07, color: white, weight: .bold, maxLines: 2))
            if let label = d.episodeLabel { lines.append(Line(text: label, size: h * 0.036, color: grey, weight: .medium, maxLines: 1)) }
            if let name = d.episodeTitle { lines.append(Line(text: name, size: h * 0.05, color: white, weight: .semibold, maxLines: 2)) }
            let facts: [String] = [d.airDate, d.network, d.runtimeText].compactMap { $0 }
            if !facts.isEmpty { lines.append(Line(text: facts.joined(separator: "  ·  "), size: h * 0.03, color: grey, weight: .regular, maxLines: 1)) }
        } else {
            lines.append(Line(text: details?.title ?? title, size: h * 0.075, color: white, weight: .bold, maxLines: 2))
            let year: String? = details?.year.map { String($0) }
            let facts: [String] = [year, details?.runtimeText, details?.certificate].compactMap { $0 }
            if !facts.isEmpty { lines.append(Line(text: facts.joined(separator: "  ·  "), size: h * 0.034, color: grey, weight: .regular, maxLines: 1)) }
            if let genres = details?.genres, !genres.isEmpty {
                lines.append(Line(text: genres.joined(separator: ", "), size: h * 0.03, color: grey, weight: .regular, maxLines: 1))
            }
            if let directors = details?.directors, !directors.isEmpty {
                lines.append(Line(text: "Directed by " + directors.joined(separator: ", "), size: h * 0.032, color: white, weight: .regular, maxLines: 1))
            }
            if let cast = details?.cast, !cast.isEmpty {
                lines.append(Line(text: "Starring " + cast.prefix(5).joined(separator: ", "), size: h * 0.032, color: white, weight: .regular, maxLines: 2))
            }
        }
        if let ratings = details?.ratings, !ratings.isEmpty {
            let shown: [String] = ratings.prefix(3).map { rating in
                let value = rating.value.split(separator: "/").first.map(String.init) ?? rating.value
                return "\(rating.source) \(value)"
            }
            lines.append(Line(text: shown.joined(separator: "   "), size: h * 0.032, color: gold, weight: .semibold, maxLines: 1))
        }

        let textWidth = max(w * 0.3, w * 0.92 - textLeft)
        var measured: [(NSAttributedString, CGFloat)] = []
        var total: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: line.size, weight: line.weight),
                .foregroundColor: line.color,
                .paragraphStyle: paragraph,
            ]
            let string = NSAttributedString(string: line.text, attributes: attributes)
            let bounds = string.boundingRect(with: NSSize(width: textWidth, height: line.size * 1.3 * CGFloat(line.maxLines)),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let lineHeight = ceil(bounds.height) + (index == 0 ? h * 0.02 : h * 0.012)
            measured.append((string, lineHeight))
            total += lineHeight
        }
        var y = (h + total) / 2   // the top of the block, in a bottom-left coordinate system
        for (string, lineHeight) in measured {
            let rect = NSRect(x: textLeft, y: y - lineHeight, width: textWidth, height: lineHeight)
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y -= lineHeight
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    /// What the film's stream carries, so the card can be encoded the same way. An Apple TV
    /// stops at the switch from card to film when the two differ (an H.264 stereo card before
    /// 10-bit HEVC with 5.1 sound would not play), although a Mac and Samsung TVs carry on.
    struct Format: Equatable, Sendable {
        var videoCodec = "h264"
        var tenBit = false
        var fps = 24.0
        /// nil when the stream has no sound.
        var audioCodec: String? = "aac"
        var channels = 2
        var sampleRate = 48_000

        init() {}

        init(plan: StreamPlan) {
            if let v = plan.video {
                if plan.isCopyingVideo, v.codec == "hevc" {
                    videoCodec = "hevc"
                    tenBit = v.bitDepth > 8
                }
                if v.fps > 1 { fps = plan.isCopyingVideo ? v.fps : min(v.fps, 60) }
            }
            guard let a = plan.audio else { audioCodec = nil; return }
            channels = max(1, a.channels)
            if a.sampleRate > 0 { sampleRate = a.sampleRate }
            switch plan.audioAction {
            case .none:
                audioCodec = nil
            case .copy:
                audioCodec = a.codec
            case .encode(let codec, let count, _):
                audioCodec = codec.rawValue
                channels = count
                if codec == .aac { sampleRate = min(sampleRate, 48_000) }
            }
            // The Dolby encoders only take these rates.
            if ["ac3", "eac3"].contains(audioCodec ?? ""), ![32_000, 44_100, 48_000].contains(sampleRate) {
                sampleRate = 48_000
            }
        }

        /// ffmpeg's name for the channel layout, which silent audio is generated in.
        var channelLayout: String {
            switch channels {
            case 1: return "mono"
            case 3: return "2.1"
            case 4: return "quad"
            case 5: return "5.0"
            case 6: return "5.1"
            case 7: return "6.1"
            case 8: return "7.1"
            default: return "stereo"
            }
        }

        /// The common broadcast rates as exact fractions, so the card's frames line up with the film's.
        var frameRate: String {
            for (value, exact) in [(23.976, "24000/1001"), (29.97, "30000/1001"), (59.94, "60000/1001")] where abs(fps - value) < 0.01 {
                return exact
            }
            return String(format: "%.3f", fps)
        }

        var audioArguments: [String] {
            switch audioCodec {
            case "ac3": return ["-c:a", "ac3", "-b:a", "384k"]
            case "eac3": return ["-c:a", "eac3", "-b:a", "384k"]
            case "flac": return ["-c:a", "flac", "-strict", "-2"]
            case "alac": return ["-c:a", "alac"]
            case "mp3": return ["-c:a", "libmp3lame", "-b:a", "128k"]
            case "opus": return ["-c:a", "libopus", "-b:a", "128k"]
            default: return ["-c:a", "aac", "-b:a", channels > 2 ? "192k" : "96k"]
            }
        }
    }

    /// ffmpeg arguments turning the card into a short fMP4 HLS clip (`intro-init.mp4`,
    /// `intro-0.m4s`, `intro.m3u8`) with silent sound, fading in and out, in `format`.
    static func ffmpegArguments(card: URL, size: CGSize, hardware: Bool, format: Format = Format(),
                                outputDirectory dir: URL) -> [String] {
        let width = max(320, Int(size.width) / 2 * 2), height = max(180, Int(size.height) / 2 * 2)
        let pixels = format.videoCodec == "hevc" && format.tenBit ? (hardware ? "p010le" : "yuv420p10le") : "yuv420p"
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                    "-loop", "1", "-framerate", format.frameRate, "-i", card.path]
        if format.audioCodec != nil {
            args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=\(format.channelLayout):sample_rate=\(format.sampleRate)"]
        }
        args += ["-t", String(format: "%.2f", seconds),
                 // The pixel format comes last: fade works in 8 bits, and VideoToolbox refuses
                 // Main 10 if its input isn't 10-bit.
                 "-vf", String(format: "scale=%d:%d,fade=t=in:st=0:d=0.4,fade=t=out:st=%.2f:d=0.5,format=%@", width, height, seconds - 0.5, pixels),
                 "-map", "0:v"]
        args += format.audioCodec != nil ? ["-map", "1:a"] : ["-an"]
        let gop = "\(max(1, Int((format.fps * 5).rounded(.up))))"
        switch (format.videoCodec, hardware) {
        case ("hevc", true):
            args += ["-c:v", "hevc_videotoolbox", "-b:v", "6000k", "-g", gop, "-profile:v", format.tenBit ? "main10" : "main",
                     "-allow_sw", "1", "-realtime", "0", "-tag:v", "hvc1"]
        case ("hevc", false):
            args += ["-c:v", "libx265", "-preset", "veryfast", "-crf", "22", "-x265-params", "log-level=error",
                     "-profile:v", format.tenBit ? "main10" : "main", "-tag:v", "hvc1"]
        case (_, true):
            args += ["-c:v", "h264_videotoolbox", "-b:v", "6000k", "-g", gop, "-profile:v", "high", "-allow_sw", "1", "-realtime", "0"]
        default:
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-profile:v", "high"]
        }
        args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        if format.audioCodec != nil {
            args += format.audioArguments + ["-ac", "\(format.channels)", "-ar", "\(format.sampleRate)", "-shortest"]
        }
        args += ["-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_segment_type", "fmp4",
                 "-hls_fmp4_init_filename", "intro-init.mp4", "-hls_flags", "independent_segments+temp_file",
                 "-hls_segment_filename", dir.appendingPathComponent("intro-%d.m4s").path,
                 dir.appendingPathComponent("intro.m3u8").path]
        return args
    }
}
